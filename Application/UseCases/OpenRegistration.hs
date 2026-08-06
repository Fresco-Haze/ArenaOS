module Application.UseCases.OpenRegistration
    ( openRegistration
    , OpenRegistrationError(..)
    ) where

import Domain.Tournament (TournamentId, TournamentState(Published, RegistrationOpen))
import Domain.TournamentHistory (TournamentHistoryEvent(RegistrationOpened))
import Domain.Ids (UserId)

import Shell.Persistence.Port (TournamentRepository, TournamentHistoryRepository, Transactional(..))
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization (AuthorizationError, requireTournamentOwner)
import Application.Internal.LifecycleTransition (LifecycleError, requireTournamentState)

data OpenRegistrationError
    = Unauthorized AuthorizationError
    | InvalidLifecycle LifecycleError
    deriving (Eq, Show)

openRegistration
    :: (TournamentRepository m, TournamentHistoryRepository m, Transactional m)
    => UserId
    -> TournamentId
    -> m (Either OpenRegistrationError ())
openRegistration currentUser tid = do
    tournament <- Repo.getTournament tid
    case requireTournamentOwner currentUser tournament of
        Left err -> pure (Left (Unauthorized err))
        Right () ->
            case requireTournamentState Published tournament of
                Left err -> pure (Left (InvalidLifecycle err))
                Right () -> do
                    withTxN $ do
                        Repo.updateTournamentState tid RegistrationOpen
                        Repo.recordHistoryEvent tid RegistrationOpened
                    pure (Right ())