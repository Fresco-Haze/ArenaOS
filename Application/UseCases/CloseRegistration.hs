module Application.UseCases.CloseRegistration
    ( closeRegistration
    , CloseRegistrationError(..)
    , selectExpiredRegistrations
    , closeExpiredRegistrations
    ) where

import Data.Time (UTCTime)
import Domain.Tournament (Tournament(..), TournamentId, TournamentState(RegistrationOpen, RegistrationClosed))
import Domain.TournamentHistory (TournamentHistoryEvent(RegistrationClosedEvent))
import Domain.Ids (UserId)

import Shell.Persistence.Port (TournamentRepository, TournamentHistoryRepository, Transactional(..))
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization (AuthorizationError, requireTournamentOwner)
import Application.Internal.LifecycleTransition (LifecycleError, requireTournamentState)

data CloseRegistrationError
    = Unauthorized AuthorizationError
    | InvalidLifecycle LifecycleError
    deriving (Eq, Show)

closeRegistration
    :: (TournamentRepository m, TournamentHistoryRepository m, Transactional m)
    => UserId
    -> TournamentId
    -> m (Either CloseRegistrationError ())
closeRegistration currentUser tid = do
    tournament <- Repo.getTournament tid
    case requireTournamentOwner currentUser tournament of
        Left err -> pure (Left (Unauthorized err))
        Right () ->
            case requireTournamentState RegistrationOpen tournament of
                Left err -> pure (Left (InvalidLifecycle err))
                Right () -> do
                    withTxN $ do
                        Repo.updateTournamentState tid RegistrationClosed
                        Repo.recordHistoryEvent tid RegistrationClosedEvent
                    pure (Right ())

-- v0.15: tournaments still open for registration whose deadline has passed.
-- Strictly before `now`: a deadline equal to now still accepts registrations.
selectExpiredRegistrations :: UTCTime -> [Tournament] -> [Tournament]
selectExpiredRegistrations now = filter expired
  where
    expired t = tournamentState t == RegistrationOpen
             && maybe False (< now) (tournamentRegistrationDeadline t)

-- Closes every expired registration in one pass. No user is involved: the
-- deadline is the authority. Same two writes as a manual close, one
-- transaction per tournament. The caller holds the database lock.
closeExpiredRegistrations
    :: (TournamentRepository m, TournamentHistoryRepository m, Transactional m)
    => UTCTime -> m [TournamentId]
closeExpiredRegistrations now = do
    ts <- Repo.listAllTournaments
    let expired = selectExpiredRegistrations now ts
    mapM_ closeOne expired
    pure (map tournamentId expired)
  where
    closeOne t = withTxN $ do
        Repo.updateTournamentState (tournamentId t) RegistrationClosed
        Repo.recordHistoryEvent (tournamentId t) RegistrationClosedEvent
