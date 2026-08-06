module Application.UseCases.UpdateTournamentName
    ( updateTournamentName
    , UpdateTournamentNameError(..)
    ) where

import Domain.Tournament (TournamentId, TournamentName, TournamentState(InProgress, Completed, Cancelled))
import Domain.TournamentHistory (TournamentHistoryEvent(ConfigurationChanged), ChangedField(FieldName))
import Domain.Ids (UserId)

import Shell.Persistence.Port (TournamentRepository, TournamentHistoryRepository, Transactional(..))
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization (AuthorizationError, requireTournamentOwner)
import Application.Internal.LifecycleTransition (LifecycleError, requireTournamentStateNotIn)

data UpdateTournamentNameError
    = Unauthorized AuthorizationError
    | InvalidLifecycle LifecycleError
    deriving (Eq, Show)

updateTournamentName
    :: (TournamentRepository m, TournamentHistoryRepository m, Transactional m)
    => UserId
    -> TournamentId
    -> TournamentName
    -> m (Either UpdateTournamentNameError ())
updateTournamentName currentUser tid newName = do
    tournament <- Repo.getTournament tid
    case requireTournamentOwner currentUser tournament of
        Left err -> pure (Left (Unauthorized err))
        Right () ->
            case requireTournamentStateNotIn [InProgress, Completed, Cancelled] tournament of
                Left err -> pure (Left (InvalidLifecycle err))
                Right () -> do
                    withTxN $ do
                        Repo.updateTournamentName tid newName
                        Repo.recordHistoryEvent tid (ConfigurationChanged FieldName)
                    pure (Right ())