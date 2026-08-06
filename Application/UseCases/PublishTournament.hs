module Application.UseCases.PublishTournament
    ( publishTournament
    , PublishTournamentError(..)
    ) where

import Domain.Tournament (TournamentId, TournamentState(Draft, Published))
import Domain.TournamentHistory (TournamentHistoryEvent(TournamentPublished))
import Domain.Ids (UserId)

import Shell.Persistence.Port (TournamentRepository, TournamentHistoryRepository, Transactional(..))
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization (AuthorizationError, requireTournamentOwner)
import Application.Internal.LifecycleTransition (LifecycleError, requireTournamentState)

data PublishTournamentError
    = Unauthorized AuthorizationError
    | InvalidLifecycle LifecycleError
    deriving (Eq, Show)

publishTournament
    :: (TournamentRepository m, TournamentHistoryRepository m, Transactional m)
    => UserId
    -> TournamentId
    -> m (Either PublishTournamentError ())
publishTournament currentUser tid = do
    tournament <- Repo.getTournament tid
    case requireTournamentOwner currentUser tournament of
        Left err -> pure (Left (Unauthorized err))
        Right () ->
            case requireTournamentState Draft tournament of
                Left err -> pure (Left (InvalidLifecycle err))
                Right () -> do
                    withTxN $ do
                        Repo.updateTournamentState tid Published
                        Repo.recordHistoryEvent tid TournamentPublished
                    pure (Right ())