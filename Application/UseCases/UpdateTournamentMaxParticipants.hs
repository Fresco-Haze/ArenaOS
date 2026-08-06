module Application.UseCases.UpdateTournamentMaxParticipants
    ( updateTournamentMaxParticipants
    , UpdateTournamentMaxParticipantsError(..)
    ) where

import Domain.Tournament (TournamentId, TournamentState(InProgress, Completed, Cancelled))
import Domain.TournamentHistory (TournamentHistoryEvent(ConfigurationChanged), ChangedField(FieldMaxParticipants))
import Domain.Ids (UserId)

import Shell.Persistence.Port (TournamentRepository, RegistrationRepository, TournamentHistoryRepository, Transactional(..))
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization (AuthorizationError, requireTournamentOwner)
import Application.Internal.LifecycleTransition (LifecycleError, requireTournamentStateNotIn)

data UpdateTournamentMaxParticipantsError
    = Unauthorized AuthorizationError
    | InvalidLifecycle LifecycleError
    | BelowRegistrationCount
    deriving (Eq, Show)

updateTournamentMaxParticipants
    :: (TournamentRepository m, RegistrationRepository m, TournamentHistoryRepository m, Transactional m)
    => UserId
    -> TournamentId
    -> Int
    -> m (Either UpdateTournamentMaxParticipantsError ())
updateTournamentMaxParticipants currentUser tid newMax = do
    tournament <- Repo.getTournament tid
    case requireTournamentOwner currentUser tournament of
        Left err -> pure (Left (Unauthorized err))
        Right () ->
            case requireTournamentStateNotIn [InProgress, Completed, Cancelled] tournament of
                Left err -> pure (Left (InvalidLifecycle err))
                Right () -> do
                    registrations <- Repo.listRegistrations tid
                    if newMax < length registrations
                        then pure (Left BelowRegistrationCount)
                        else do
                            withTxN $ do
                                Repo.updateTournamentMaxParticipants tid newMax
                                Repo.recordHistoryEvent tid (ConfigurationChanged FieldMaxParticipants)
                            pure (Right ())