module Application.UseCases.UpdateTournamentFormat
    ( updateTournamentFormat
    , UpdateTournamentFormatError(..)
    ) where

import Domain.Tournament (TournamentId, TournamentFormat, TournamentState(InProgress, Completed, Cancelled))
import Domain.TournamentHistory (TournamentHistoryEvent(ConfigurationChanged), ChangedField(FieldFormat))
import Domain.Ids (UserId)

import Shell.Persistence.Port (TournamentRepository, TournamentHistoryRepository, Transactional(..))
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization (AuthorizationError, requireTournamentOwner)
import Application.Internal.LifecycleTransition (LifecycleError, requireTournamentStateNotIn)

data UpdateTournamentFormatError
    = Unauthorized AuthorizationError
    | InvalidLifecycle LifecycleError
    deriving (Eq, Show)

updateTournamentFormat
    :: (TournamentRepository m, TournamentHistoryRepository m, Transactional m)
    => UserId
    -> TournamentId
    -> TournamentFormat
    -> m (Either UpdateTournamentFormatError ())
updateTournamentFormat currentUser tid newFormat = do
    tournament <- Repo.getTournament tid
    case requireTournamentOwner currentUser tournament of
        Left err -> pure (Left (Unauthorized err))
        Right () ->
            case requireTournamentStateNotIn [InProgress, Completed, Cancelled] tournament of
                Left err -> pure (Left (InvalidLifecycle err))
                Right () -> do
                    withTxN $ do
                        Repo.updateTournamentFormat tid newFormat
                        Repo.recordHistoryEvent tid (ConfigurationChanged FieldFormat)
                    pure (Right ())