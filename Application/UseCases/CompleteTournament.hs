module Application.UseCases.CompleteTournament
  ( completeTournament
  ) where

import Data.List (find, maximumBy)
import Data.Ord (comparing)

import Domain.Tournament (Tournament(..), TournamentId, TournamentState(..))
import Domain.Bracket (BracketNode(..), BracketNodeId)
import Domain.Match (Match(..), MatchStatus(..), MatchOutcome(..))
import Domain.Match hiding (Completed, Cancelled)
import Domain.TournamentError (TournamentError(..))

import Shell.Persistence.Port
  ( TournamentRepository
  , BracketRepository
  , MatchRepository
  )
import qualified Shell.Persistence.Port as Repo

completeTournament
  :: (TournamentRepository m, BracketRepository m, MatchRepository m)
  => TournamentId
  -> m (Either TournamentError Tournament)
completeTournament tid = do
  tournament <- Repo.getTournament tid
  case tournamentState tournament of
    Domain.Tournament.Completed -> pure (Left TournamentAlreadyCompleted)
    Domain.Tournament.Cancelled -> pure (Left TournamentAlreadyCancelled)
    _         -> case tournamentBracket tournament of
      Nothing -> pure (Left TournamentNotComplete)  -- no bracket generated yet
      Just bracketId -> do
        (_, nodes) <- Repo.getBracket bracketId
        matches    <- Repo.listMatchesForBracket bracketId

        case findChampionMatch nodes matches of
          Nothing -> pure (Left TournamentNotComplete)
          Just _  -> do
            let updated = tournament { tournamentState = Domain.Tournament.Completed }
            Repo.saveTournament updated
            pure (Right updated)

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