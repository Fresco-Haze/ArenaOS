module Application.UseCases.CompleteTournament
  ( completeTournament
  , CompleteTournamentError(..)
  ) where

import Data.Bifunctor (first)
import Data.List (find, maximumBy)
import Data.Ord (comparing)


import Domain.Tournament (Tournament(..), TournamentId, TournamentFormat(..), TournamentState(..))
import Domain.Bracket (BracketNode(..), BracketNodeId, MatchSlot(..),Bracket(..))
import Domain.Match (Match(..), MatchStatus(..), MatchOutcome(..))
import Domain.Match hiding (Completed, Cancelled)
import Domain.TournamentError (TournamentError(..))
import Domain.TournamentHistory (TournamentHistoryEvent(TournamentCompleted))
import Domain.Ids (UserId)
import Domain.Participant (Participant)

import Shell.Persistence.Port
  ( TournamentRepository
  , BracketRepository
  , MatchRepository
  , TournamentHistoryRepository
  , Transactional(..)
  )
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization (AuthorizationError, requireTournamentOwner)
import Data.Maybe (isJust)


data CompleteTournamentError
  = Unauthorized AuthorizationError
  | InvalidCompletion TournamentError
  deriving (Eq, Show)

completeTournament currentUser tid = do
  tournament <- Repo.getTournament tid
  case first Unauthorized (requireTournamentOwner currentUser tournament) of
    Left err -> pure (Left err)
    Right () ->
      fmap (first InvalidCompletion) $ case tournamentState tournament of
        Domain.Tournament.Completed -> pure (Left TournamentAlreadyCompleted)
        Domain.Tournament.Cancelled -> pure (Left TournamentAlreadyCancelled)
        _         -> case tournamentBracket tournament of
          Nothing -> pure (Left TournamentNotComplete)
          Just bracketId -> do
            (bracket, nodes) <- Repo.getBracket bracketId
            matches    <- Repo.listMatchesForBracket bracketId

            -- Dispatch on tournamentFormat directly rather than inferring
            -- it from GF1/reset-node presence -- (Nothing,Nothing) is true
            -- of RoundRobin AND SingleElimination alike, so the old
            -- presence-based branch silently routed RoundRobin into
            -- findChampionMatch, which is wrong for it in every direction:
            -- every RoundRobin node has nodeRound=1 (deferred round
            -- scheduling), so maximumBy picked one arbitrary match rather
            -- than checking all of them, and championOutcome's
            -- Winner/Forfeit/Disqualification-only match excludes Draw,
            -- which is a valid RoundRobin terminal outcome by our own
            -- locked completion criterion.
            let isComplete = case tournamentFormat tournament of
                  RoundRobin ->
                    not (null matches) && all (\m -> matchStatus m == Domain.Match.Completed) matches
                  _ ->
                    case (bracketGF1NodeId bracket, bracketResetNodeId bracket) of
                      (Just gf1Id, Just resetId) ->
                        findChampionMatchDoubleElim gf1Id (Just resetId) nodes matches /= Nothing
                      _ ->
                        findChampionMatch nodes matches /= Nothing   -- unchanged single-elim path

            if not isComplete
              then pure (Left TournamentNotComplete)
              else do
                let updated = tournament { tournamentState = Domain.Tournament.Completed }
                withTxN $ do
                    Repo.saveTournament updated
                    Repo.recordHistoryEvent tid TournamentCompleted
                pure (Right updated)

-- new, alongside findChampionMatch
findChampionMatchDoubleElim
  :: BracketNodeId -> Maybe BracketNodeId -> [BracketNode] -> [Match] -> Maybe Match
findChampionMatchDoubleElim gf1Id mResetId nodes matches = do
  gf1Node  <- find ((== gf1Id) . nodeId) nodes
  gf1Match <- lookupMatchForNode gf1Id matches >>= championOutcome
  winner   <- matchOutcomeWinner gf1Match
  case nodeSlotB gf1Node of
    Filled lbChampion
      | winner == lbChampion ->
          mResetId >>= \rid -> lookupMatchForNode rid matches >>= championOutcome
      | otherwise -> Just gf1Match
    _ -> Nothing

matchOutcomeWinner :: Match -> Maybe Participant
matchOutcomeWinner m = case matchOutcome m of
  Just (Winner p)           -> Just p
  Just (Forfeit p)          -> Just p
  Just (Disqualification p) -> Just p
  _                          -> Nothing


-- | The tournament is complete iff the final BracketNode (highest
-- nodeRound -- single-elimination only; double-elim would need a
-- different "final node" rule for the grand finals, see backlog) has a
-- Completed Match whose outcome names an advancing Participant.
--
-- Status and outcome are checked together in one case, since "champion
-- determined" is a single business rule, not two independent predicates.
findChampionMatch :: [BracketNode] -> [Match] -> Maybe Match
findChampionMatch [] _ = Nothing
findChampionMatch nodes matches = do
  let finalNode = maximumBy (comparing nodeRound) nodes
  m <- lookupMatchForNode (nodeId finalNode) matches
  championOutcome m

lookupMatchForNode :: BracketNodeId -> [Match] -> Maybe Match
lookupMatchForNode nid = find (\m -> matchBracketNode m == nid)

championOutcome :: Match -> Maybe Match
championOutcome m = case (matchStatus m, matchOutcome m) of
  (Domain.Match.Completed, Just (Winner _))           -> Just m
  (Domain.Match.Completed, Just (Forfeit _))          -> Just m
  (Domain.Match.Completed, Just (Disqualification _)) -> Just m
  _                                      -> Nothing