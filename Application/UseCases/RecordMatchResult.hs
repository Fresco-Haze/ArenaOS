module Application.UseCases.RecordMatchResult
  ( recordMatchResult
  , RecordMatchResultError(..)
  ) where

import Control.Exception (assert)
import Data.Bifunctor (first)

import Domain.Match (Match(..), MatchId, MatchStatus(..), MatchOutcome(..))
import Domain.Bracket (BracketId, BracketNode(..), MatchSlot(..), BracketNodeId)
import Domain.Participant (Participant)
import Domain.Tournament (TournamentId)
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

data RecordMatchResultError
  = Unauthorized AuthorizationError
  | InvalidMatch MatchError
  deriving (Eq, Show)

recordMatchResult
  :: ( MatchRepository m
     , BracketRepository m
     , ParticipantRepository m
     , TournamentRepository m
     , Transactional m
     )
  => UserId
  -> MatchId
  -> MatchOutcome
  -> m (Either RecordMatchResultError Match)
recordMatchResult currentUser matchId outcome = do
  match      <- Repo.getMatch matchId
  tournament <- Repo.getTournament (matchTournament match)

  case first Unauthorized (requireTournamentOwner currentUser tournament) of
    Left err -> pure (Left err)
    Right () ->
      fmap (first InvalidMatch) $ case outcomeParticipant outcome of
        Just p | p /= matchCompetitorA match && p /= matchCompetitorB match ->
          pure (Left (ParticipantNotInMatch p))
        _ -> case matchStatus match of
          InProgress -> withTxN $ do
            let completed = Advancement.completeMatch outcome match
            Repo.saveMatch completed

            case outcome of
              Winner p           -> advanceAndMaterialize completed p
              Forfeit p          -> advanceAndMaterialize completed p
              Disqualification p -> advanceAndMaterialize completed p
              Draw                -> pure ()
              NoContest           -> pure ()

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

  let readyBefore  = Materialization.readyNodes nodes
      updatedNodes = Advancement.propagateWinner (matchBracketNode completed) winner nodes
      readyAfter   = Materialization.readyNodes updatedNodes
      newlyReady   = filter (\n -> n `notElem` readyBefore) readyAfter

  case filter (\(old, new) -> old /= new) (zip nodes updatedNodes) of
    [] ->
      -- No downstream node references this match's source id -- there's
      -- nothing left to propagate into. (For a single-elimination bracket
      -- this happens exactly at the final; the check itself doesn't know
      -- or care that it's the final, which is the point.)
      pure ()
    ((_, changedNode) : _) ->
      Repo.updateNodeSlots changedNode

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