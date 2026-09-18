module Application.UseCases.SetMatchSchedule
  ( setMatchSchedule
  , SetMatchScheduleError(..)
  ) where

import Data.Bifunctor (first)
import Data.Time (UTCTime)

import Domain.Match (Match(..), MatchId, MatchStatus(..))
import Domain.MatchError (MatchError(..))
import Domain.Ids (UserId)

import Shell.Persistence.Port (MatchRepository, TournamentRepository)
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization (AuthorizationError, requireTournamentOwner)
import Application.Internal.LifecycleTransition (LifecycleError, requireSchedulable)

data SetMatchScheduleError
  = Unauthorized AuthorizationError
  | InvalidLifecycle LifecycleError
  | InvalidMatch MatchError
  deriving (Eq, Show)

setMatchSchedule
  :: (MatchRepository m, TournamentRepository m)
  => UserId -> MatchId -> Maybe UTCTime
  -> m (Either SetMatchScheduleError Match)
setMatchSchedule currentUser mid newSchedule = do
  match      <- Repo.getMatch mid
  tournament <- Repo.getTournament (matchTournament match)
  case first Unauthorized (requireTournamentOwner currentUser tournament) of
    Left err -> pure (Left err)
    Right () ->
      case first InvalidLifecycle (requireSchedulable tournament) of
        Left err -> pure (Left err)
        Right () ->
          case matchStatus match of
            Scheduled -> do
              let updated = match { matchScheduledStart = newSchedule }
              Repo.saveMatch updated
              pure (Right updated)
            status -> pure (Left (InvalidMatch (MatchNotScheduled status)))