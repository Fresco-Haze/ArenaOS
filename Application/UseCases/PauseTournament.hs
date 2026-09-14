module Application.UseCases.PauseTournament
    ( pauseTournament
    , PauseTournamentError(..)
    ) where

import Domain.Tournament (TournamentId, TournamentState(InProgress, Paused))
import Domain.TournamentHistory (TournamentHistoryEvent(TournamentPaused))
import Domain.Ids (UserId)

import Shell.Persistence.Port (TournamentRepository, TournamentHistoryRepository, Transactional(..))
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization (AuthorizationError, requireTournamentOwner)
import Application.Internal.LifecycleTransition (LifecycleError, requireTournamentState)

data PauseTournamentError
    = Unauthorized AuthorizationError
    | InvalidLifecycle LifecycleError
    deriving (Eq, Show)

pauseTournament
    :: (TournamentRepository m, TournamentHistoryRepository m, Transactional m)
    => UserId -> TournamentId -> m (Either PauseTournamentError ())
pauseTournament currentUser tid = do
    tournament <- Repo.getTournament tid
    case requireTournamentOwner currentUser tournament of
        Left err -> pure (Left (Unauthorized err))
        Right () ->
            case requireTournamentState InProgress tournament of
                Left err -> pure (Left (InvalidLifecycle err))
                Right () -> do
                    withTxN $ do
                        Repo.updateTournamentState tid Paused
                        Repo.recordHistoryEvent tid TournamentPaused
                    pure (Right ())