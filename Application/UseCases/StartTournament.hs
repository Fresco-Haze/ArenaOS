module Application.UseCases.StartTournament
    ( startTournament
    , StartTournamentError(..)
    ) where

import Domain.Tournament (Tournament(..), TournamentId, TournamentState(RegistrationClosed, InProgress))
import Domain.TournamentHistory (TournamentHistoryEvent(TournamentStarted))
import Domain.Ids (UserId)

import Shell.Persistence.Port (TournamentRepository, TournamentHistoryRepository, Transactional(..))
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization (AuthorizationError, requireTournamentOwner)
import Application.Internal.LifecycleTransition (LifecycleError, requireTournamentState)

data StartTournamentError
    = Unauthorized AuthorizationError
    | InvalidLifecycle LifecycleError
    | BracketNotGenerated
    deriving (Eq, Show)

startTournament
    :: (TournamentRepository m, TournamentHistoryRepository m, Transactional m)
    => UserId
    -> TournamentId
    -> m (Either StartTournamentError ())
startTournament currentUser tid = do
    tournament <- Repo.getTournament tid
    case requireTournamentOwner currentUser tournament of
        Left err -> pure (Left (Unauthorized err))
        Right () ->
            case requireTournamentState RegistrationClosed tournament of
                Left err -> pure (Left (InvalidLifecycle err))
                Right () ->
                    case tournamentBracket tournament of
                        Nothing -> pure (Left BracketNotGenerated)
                        Just _  -> do
                            withTxN $ do
                                Repo.updateTournamentState tid InProgress
                                Repo.recordHistoryEvent tid TournamentStarted
                            pure (Right ())