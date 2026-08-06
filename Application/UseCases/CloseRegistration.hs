module Application.UseCases.CloseRegistration
    ( closeRegistration
    , CloseRegistrationError(..)
    ) where

import Domain.Tournament (TournamentId, TournamentState(RegistrationOpen, RegistrationClosed))
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