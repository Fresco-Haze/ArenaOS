module Application.UseCases.UpdateTournamentVisibility
    ( updateTournamentVisibility
    , UpdateTournamentVisibilityError(..)
    ) where

import Domain.Tournament (TournamentId, Visibility, TournamentState(InProgress, Completed, Cancelled))
import Domain.TournamentHistory (TournamentHistoryEvent(ConfigurationChanged), ChangedField(FieldVisibility))
import Domain.Ids (UserId)

import Shell.Persistence.Port (TournamentRepository, TournamentHistoryRepository, Transactional(..))
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization (AuthorizationError, requireTournamentOwner)
import Application.Internal.LifecycleTransition (LifecycleError, requireTournamentStateNotIn)

data UpdateTournamentVisibilityError
    = Unauthorized AuthorizationError
    | InvalidLifecycle LifecycleError
    deriving (Eq, Show)

updateTournamentVisibility
    :: (TournamentRepository m, TournamentHistoryRepository m, Transactional m)
    => UserId
    -> TournamentId
    -> Visibility
    -> m (Either UpdateTournamentVisibilityError ())
updateTournamentVisibility currentUser tid newVisibility = do
    tournament <- Repo.getTournament tid
    case requireTournamentOwner currentUser tournament of
        Left err -> pure (Left (Unauthorized err))
        Right () ->
            case requireTournamentStateNotIn [InProgress, Completed, Cancelled] tournament of
                Left err -> pure (Left (InvalidLifecycle err))
                Right () -> do
                    withTxN $ do
                        Repo.updateTournamentVisibility tid newVisibility
                        Repo.recordHistoryEvent tid (ConfigurationChanged FieldVisibility)
                    pure (Right ())