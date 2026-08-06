module Application.UseCases.CancelTournament
    ( cancelTournament
    , CancelTournamentError(..)
    ) where

import Domain.Tournament (TournamentId, TournamentState(Completed, Cancelled))
import Domain.TournamentHistory (TournamentHistoryEvent(TournamentCancelled))
import Domain.Ids (UserId)

import Shell.Persistence.Port (TournamentRepository, TournamentHistoryRepository, Transactional(..))
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization (AuthorizationError, requireTournamentOwner)
import Application.Internal.LifecycleTransition (LifecycleError, requireTournamentStateNotIn)

data CancelTournamentError
    = Unauthorized AuthorizationError
    | InvalidLifecycle LifecycleError
    | EmptyCancellationReason
    deriving (Eq, Show)

cancelTournament
    :: (TournamentRepository m, TournamentHistoryRepository m, Transactional m)
    => UserId
    -> TournamentId
    -> String
    -> m (Either CancelTournamentError ())
cancelTournament currentUser tid reason = do
    tournament <- Repo.getTournament tid
    case requireTournamentOwner currentUser tournament of
        Left err -> pure (Left (Unauthorized err))
        Right () ->
            case requireTournamentStateNotIn [Completed, Cancelled] tournament of
                Left err -> pure (Left (InvalidLifecycle err))
                Right ()
                    | null reason -> pure (Left EmptyCancellationReason)
                    | otherwise -> do
                        withTxN $ do
                            Repo.updateTournamentState tid Cancelled
                            Repo.recordHistoryEvent tid (TournamentCancelled reason)
                        pure (Right ())