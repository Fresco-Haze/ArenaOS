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
import Engine.Champion (findChampionMatch, findChampionMatchDoubleElim, lookupMatchForNode, championOutcome)


data CompleteTournamentError
  = Unauthorized AuthorizationError
  | InvalidCompletion TournamentError
  | TournamentPausedCannotComplete
  deriving (Eq, Show)

completeTournament
  :: ( TournamentRepository m, BracketRepository m, MatchRepository m
     , TournamentHistoryRepository m, Transactional m )
  => UserId -> TournamentId -> m (Either CompleteTournamentError Tournament)
completeTournament currentUser tid = do
  tournament <- Repo.getTournament tid
  case first Unauthorized (requireTournamentOwner currentUser tournament) of
    Left err -> pure (Left err)
    Right () ->
      fmap (first InvalidCompletion) $ case tournamentState tournament of
        Domain.Tournament.Completed -> pure (Left TournamentAlreadyCompleted)
        Domain.Tournament.Cancelled -> pure (Left TournamentAlreadyCancelled)
        Domain.Tournament.Paused    -> pure (Left TournamentPaused)
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
                        let championDecided =
                              findChampionMatch (bracketThirdPlaceNodeId bracket) nodes matches /= Nothing
                            thirdPlaceDecided = case bracketThirdPlaceNodeId bracket of
                              Nothing   -> True
                              Just tpId -> isJust (lookupMatchForNode tpId matches >>= championOutcome)
                        in championDecided && thirdPlaceDecided

            if not isComplete
              then pure (Left TournamentNotComplete)
              else do
                let updated = tournament { tournamentState = Domain.Tournament.Completed }
                withTxN $ do
                    Repo.saveTournament updated
                    Repo.recordHistoryEvent tid TournamentCompleted
                pure (Right updated)

