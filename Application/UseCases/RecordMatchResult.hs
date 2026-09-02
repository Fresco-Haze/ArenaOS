module Application.UseCases.RecordMatchResult
  ( recordMatchResult
  , RecordMatchResultError(..)
  , recordMatchResultInTx
  ) where

import Control.Exception (assert)
import Data.Bifunctor (first)

import Domain.Match (Match(..), MatchId, MatchStatus(..), MatchOutcome(..))
import Domain.Bracket (Bracket(..), BracketId, BracketNode(..), MatchSlot(..), BracketNodeId)
import Domain.Participant (Participant)
import Domain.Tournament (Tournament(..), TournamentId, TournamentFormat(..))
import Domain.MatchError (MatchError(..))
import Domain.Ids (UserId)
import Data.List (find)
import qualified Data.Map.Strict as Map
import Control.Monad(forM_)
import Control.Monad.IO.Class (liftIO)

import Shell.Persistence.Port
  ( MatchRepository
  , BracketRepository
  , ParticipantRepository
  , TournamentRepository
  , Transactional(..)
  , NewMatch(..)
  )
import qualified Shell.Persistence.Port as Repo

import qualified Engine.Advancement     as Advancement
import qualified Engine.Materialization as Materialization
import Shell.Persistence.SQLite.BracketRepository ()
import Application.Internal.MatchCreation (createMatchForReadyNode)
import Application.Internal.Authorization (AuthorizationError, requireTournamentOwner)
import qualified Engine.ByeResolution as ByeResolution

data RecordMatchResultError
  = Unauthorized AuthorizationError
  | InvalidMatch MatchError
  deriving (Eq, Show)

-- | Public entry point. Owns the transaction boundary so that callers
-- needing to compose additional writes (e.g. RecordEFootballResult
-- persisting a score) can share one transaction instead of nesting.
recordMatchResult
  :: ( MatchRepository m, BracketRepository m, ParticipantRepository m
     , TournamentRepository m, Transactional m )
  => UserId -> MatchId -> MatchOutcome
  -> m (Either RecordMatchResultError Match)
recordMatchResult currentUser matchId outcome =
  withTxN $ recordMatchResultInTx currentUser matchId outcome

-- | Same logic as before, unchanged -- now assumes it is already running
-- inside a transaction opened by its caller.
recordMatchResultInTx
  :: ( MatchRepository m, BracketRepository m, ParticipantRepository m
     , TournamentRepository m )
  => UserId -> MatchId -> MatchOutcome
  -> m (Either RecordMatchResultError Match)
recordMatchResultInTx currentUser matchId outcome = do
  match      <- Repo.getMatch matchId
  tournament <- Repo.getTournament (matchTournament match)
  case first Unauthorized (requireTournamentOwner currentUser tournament) of
    Left err -> pure (Left err)
    Right () ->
      fmap (first InvalidMatch) $ case outcomeParticipant outcome of
        Just p | p /= matchCompetitorA match && p /= matchCompetitorB match ->
          pure (Left (ParticipantNotInMatch p))
        Nothing | tournamentFormat tournament /= RoundRobin ->
          -- Draw/NoContest have nowhere to advance in an elimination bracket
          -- (Single/DoubleElimination) -- reject here, same validation tier
          -- as ParticipantNotInMatch, rather than writing a "completed"
          -- match that silently can't advance. RoundRobin has no such
          -- constraint (nothing ever propagates), so it falls through below.
          pure (Left (OutcomeNotAdvanceable outcome))
        _ -> case matchStatus match of
          InProgress -> do
            let completed = Advancement.completeMatch outcome match
            Repo.saveMatch completed
            case outcome of
              Winner p           -> advanceAndMaterialize completed p
              Forfeit p          -> advanceAndMaterialize completed p
              Disqualification p -> advanceAndMaterialize completed p
              Draw                -> pure ()  -- RoundRobin only, now reachable
              NoContest           -> pure ()  -- RoundRobin only, now reachable
            pure (Right completed)
          status -> pure (Left (MatchNotInProgress status))

-- | Draw and NoContest carry no advancing participant, so there's
-- nothing to validate against the match's competitors.
outcomeParticipant :: MatchOutcome -> Maybe Participant
outcomeParticipant (Winner p)           = Just p
outcomeParticipant (Forfeit p)          = Just p
outcomeParticipant (Disqualification p) = Just p
outcomeParticipant Draw                 = Nothing
outcomeParticipant NoContest            = Nothing

-- | Propagates the winner into the node this match was materialized from
-- (matchBracketNode, DI-12 -- direct lookup, no search) and materializes
-- any node that newly became ready as a result.
advanceAndMaterialize
  :: (BracketRepository m, MatchRepository m, ParticipantRepository m)
  => Match
  -> Participant
  -> m ()
advanceAndMaterialize completed winner = do
  (bracket, nodes) <- Repo.getBracket (matchBracket completed)

  let loser = if winner == matchCompetitorA completed
                then matchCompetitorB completed
                else matchCompetitorA completed

      propagated = Advancement.propagateLoser (matchBracketNode completed) loser
                 $ Advancement.propagateWinner (matchBracketNode completed) winner nodes

      -- GF1's own node's slots (wbFinalId/lbFinalId) are never touched by
      -- this step's propagation, so it's safe to read it from the
      -- pre-update `nodes` list.
      isGF1Completion = Just (matchBracketNode completed) == bracketGF1NodeId bracket
      resetNeeded =
        case find ((== matchBracketNode completed) . nodeId) nodes of
          Just gf1Node -> Advancement.resetIsNeeded gf1Node winner
          Nothing      -> False

      -- If GF1 just completed without the reset being needed, the
      -- unconditional propagate calls above still filled the reset node
      -- to (Filled,Filled) -- overwrite it to (ByeSlot,ByeSlot) before
      -- anything downstream sees it. Single ByeSlot would spuriously trip
      -- resolveAutomaticAdvancements; both slots keeps it inert.
      voidIfUnneededReset n
        | isGF1Completion && not resetNeeded
        , Just (nodeId n) == bracketResetNodeId bracket
        = n { nodeSlotA = ByeSlot, nodeSlotB = ByeSlot }
        | otherwise = n

      voided = map voidIfUnneededReset propagated

      -- A node that just became bye-shaped as a result of THIS match's
      -- propagation (e.g. a WB loser dropping into an LB1 bye-slot node)
      -- needs the same auto-advance ByeResolution already gives byes at
      -- generation time -- otherwise it sits at (Filled,ByeSlot) forever,
      -- since readyNodes only ever recognizes (Filled,Filled). Safe to
      -- rerun over the whole list: already-resolved byes (their winner
      -- already propagated forward) are no-ops, and the just-voided reset
      -- node is (ByeSlot,ByeSlot), which isByeNode deliberately excludes.
      finalNodes = ByeResolution.resolveAutomaticAdvancements voided

      readyBefore  = Materialization.readyNodes nodes
      readyAfter   = Materialization.readyNodes finalNodes
      newlyReady   = filter (\n -> n `notElem` readyBefore) readyAfter
      changedNodes = map snd $ filter (\(old, new) -> old /= new) (zip nodes finalNodes)
  mapM_ Repo.updateNodeSlots changedNodes
  mapM_ (materializeOneNode (matchTournament completed) (matchBracket completed)) newlyReady
-- BACKLOG: this duplicates GenerateBracket.createMatchForNode's shape
-- (resolve competitors -> createMatch w/ DI-12 node id -> materializeMatch
-- -> saveMatch). Left duplicated for now to finish v0.1's use case set;
-- refactor into a shared Application-layer helper afterward (not Engine --
-- this depends on repositories). Tracked so it isn't silently forgotten.
materializeOneNode
  :: (MatchRepository m, ParticipantRepository m, BracketRepository m)
  => TournamentId
  -> BracketId
  -> BracketNodeId
  -> m ()
materializeOneNode tid bid nodeId' = do
  (_, nodes) <- Repo.getBracket bid
  let node = case find (\n -> nodeId n == nodeId') nodes of
        Just n  -> n
        Nothing -> error "Invariant violated: bracket node not found for id."
      isReady = case (nodeSlotA node, nodeSlotB node) of
        (Filled _, Filled _) -> True
        _                     -> False
  newMatchId <- createMatchForReadyNode tid bid (nodeId node) node
  case Materialization.materializeMatch newMatchId tid bid (Map.singleton (nodeId node) (nodeId node)) node of
    Just newMatch -> Repo.saveMatch newMatch
    Nothing       -> error "Invariant violated: ready bracket node failed materialization."