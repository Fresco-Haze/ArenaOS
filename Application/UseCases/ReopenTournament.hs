module Application.UseCases.ReopenTournament
    ( reopenTournament
    , ReopenTournamentError(..)
    ) where

import Domain.Tournament (TournamentId, TournamentState(Completed, InProgress))
import Domain.TournamentHistory (TournamentHistoryEvent(TournamentReopened, reopeningReason))
import Domain.Ids (UserId)

import Shell.Persistence.Port (TournamentRepository, TournamentHistoryRepository, Transactional(..))
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization (AuthorizationError, requireTournamentOwner)
import Application.Internal.LifecycleTransition (LifecycleError, requireTournamentState)

data ReopenTournamentError
    = Unauthorized AuthorizationError
    | InvalidLifecycle LifecycleError
    | EmptyReopeningReason
    deriving (Eq, Show)

reopenTournament
    :: (TournamentRepository m, TournamentHistoryRepository m, Transactional m)
    => UserId
    -> TournamentId
    -> String
    -> m (Either ReopenTournamentError ())
reopenTournament currentUser tid reason = do
    tournament <- Repo.getTournament tid
    case requireTournamentOwner currentUser tournament of
        Left err -> pure (Left (Unauthorized err))
        Right () ->
            case requireTournamentState Completed tournament of
                Left err -> pure (Left (InvalidLifecycle err))
                Right ()
                    | null reason -> pure (Left EmptyReopeningReason)
                    | otherwise -> do
                        withTxN $ do
                            Repo.updateTournamentState tid InProgress
                            Repo.recordHistoryEvent tid (TournamentReopened { reopeningReason = reason })
                        pure (Right ())