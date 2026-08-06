module Application.UseCases.GetTournamentHistory
    ( getTournamentHistory
    , GetTournamentHistoryError(..)
    ) where

import Domain.Tournament (TournamentId)
import Domain.TournamentHistory (TournamentHistoryEntry)
import Domain.Ids (UserId)

import Shell.Persistence.Port (TournamentRepository, TournamentHistoryRepository)
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization (AuthorizationError, requireTournamentOwner)

data GetTournamentHistoryError
    = Unauthorized AuthorizationError
    deriving (Eq, Show)

getTournamentHistory
    :: (TournamentRepository m, TournamentHistoryRepository m)
    => UserId
    -> TournamentId
    -> m (Either GetTournamentHistoryError [TournamentHistoryEntry])
getTournamentHistory currentUser tid = do
    tournament <- Repo.getTournament tid
    case requireTournamentOwner currentUser tournament of
        Left err -> pure (Left (Unauthorized err))
        Right () -> do
            entries <- Repo.getTournamentHistory tid
            pure (Right entries)