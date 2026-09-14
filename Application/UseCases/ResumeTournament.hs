module Application.UseCases.ResumeTournament
    ( resumeTournament
    , ResumeTournamentError(..)
    ) where

import Domain.Tournament (TournamentId, TournamentState(Paused, InProgress))
import Domain.TournamentHistory (TournamentHistoryEvent(TournamentResumed))
import Domain.Ids (UserId)

import Shell.Persistence.Port (TournamentRepository, TournamentHistoryRepository, Transactional(..))
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization (AuthorizationError, requireTournamentOwner)
import Application.Internal.LifecycleTransition (LifecycleError, requireTournamentState)

data ResumeTournamentError
    = Unauthorized AuthorizationError
    | InvalidLifecycle LifecycleError
    deriving (Eq, Show)

resumeTournament
    :: (TournamentRepository m, TournamentHistoryRepository m, Transactional m)
    => UserId -> TournamentId -> m (Either ResumeTournamentError ())
resumeTournament currentUser tid = do
    tournament <- Repo.getTournament tid
    case requireTournamentOwner currentUser tournament of
        Left err -> pure (Left (Unauthorized err))
        Right () ->
            case requireTournamentState Paused tournament of
                Left err -> pure (Left (InvalidLifecycle err))
                Right () -> do
                    withTxN $ do
                        Repo.updateTournamentState tid InProgress
                        Repo.recordHistoryEvent tid TournamentResumed
                    pure (Right ())