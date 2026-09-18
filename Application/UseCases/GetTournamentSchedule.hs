module Application.UseCases.GetTournamentSchedule
  ( getTournamentSchedule
  , GetTournamentScheduleError(..)
  ) where

import Data.Bifunctor (first)
import Data.List (sortBy)
import Data.Ord (comparing)

import Domain.Match (Match(..))
import Domain.Tournament (Tournament(..), TournamentId)
import Domain.Ids (UserId)

import Shell.Persistence.Port (TournamentRepository, MatchRepository)
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization (AuthorizationError, requireTournamentVisible)

data GetTournamentScheduleError
  = Unauthorized AuthorizationError
  | BracketNotGenerated
  deriving (Eq, Show)

-- | Pure read, no Transactional constraint -- nothing here writes.
-- No format gate (unlike GetRoundRobinStandings): a schedule is
-- meaningful for every format. No lifecycle gate either -- viewing a
-- schedule doesn't inherit SetMatchSchedule's mutation restrictions;
-- a Completed or Paused tournament's schedule is still valid to see.
--
-- Sorted with Nothing entries LAST, deliberately opposite of Maybe's
-- derived Ord (which puts Nothing first) -- explicit comparator
-- required, not `comparing matchScheduledStart`.
getTournamentSchedule
  :: (TournamentRepository m, MatchRepository m)
  => UserId
  -> TournamentId
  -> m (Either GetTournamentScheduleError [Match])
getTournamentSchedule caller tid = do
  tournament <- Repo.getTournament tid
  case first Unauthorized (requireTournamentVisible caller tournament) of
    Left err -> pure (Left err)
    Right () ->
      case tournamentBracket tournament of
        Nothing -> pure (Left BracketNotGenerated)
        Just bracketId -> do
          matches <- Repo.listMatchesForBracket bracketId
          pure (Right (sortBy scheduleOrder matches))
  where
    scheduleOrder m1 m2 = case (matchScheduledStart m1, matchScheduledStart m2) of
      (Nothing, Nothing) -> EQ
      (Nothing, Just _)  -> GT
      (Just _, Nothing)  -> LT
      (Just t1, Just t2) -> compare t1 t2