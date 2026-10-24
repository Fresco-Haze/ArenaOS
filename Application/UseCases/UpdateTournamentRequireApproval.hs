module Application.UseCases.UpdateTournamentRequireApproval
    ( updateTournamentRequireApproval
    , UpdateTournamentRequireApprovalError(..)
    ) where

import Domain.Tournament (TournamentId, TournamentState(InProgress, Completed, Cancelled))
import Domain.Ids (UserId)

import Shell.Persistence.Port (TournamentRepository)
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization (AuthorizationError, requireTournamentOwner)
import Application.Internal.LifecycleTransition (LifecycleError, requireTournamentStateNotIn)

data UpdateTournamentRequireApprovalError
    = Unauthorized AuthorizationError
    | InvalidLifecycle LifecycleError
    deriving (Eq, Show)

-- Owner-only; allowed until the tournament starts.
updateTournamentRequireApproval
    :: TournamentRepository m
    => UserId
    -> TournamentId
    -> Bool
    -> m (Either UpdateTournamentRequireApprovalError ())
updateTournamentRequireApproval currentUser tid newValue = do
    tournament <- Repo.getTournament tid
    case requireTournamentOwner currentUser tournament of
        Left err -> pure (Left (Unauthorized err))
        Right () ->
            case requireTournamentStateNotIn [InProgress, Completed, Cancelled] tournament of
                Left err -> pure (Left (InvalidLifecycle err))
                Right () -> do
                    Repo.updateTournamentRequireApproval tid newValue
                    pure (Right ())