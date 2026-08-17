module Application.UseCases.GetOrganizerDashboard
  ( GetOrganizerDashboardError(..)
  , getOrganizerDashboard
  ) where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Shell.Persistence.Port (TournamentRepository(..))
import Shell.Auth.Session (loadSession)
import Application.Internal.TournamentOverview (TournamentOverview, buildTournamentOverview)

data GetOrganizerDashboardError
    = SessionAbsent
    deriving (Eq, Show)

getOrganizerDashboard
    :: (MonadIO m, TournamentRepository m)
    => m (Either GetOrganizerDashboardError TournamentOverview)
getOrganizerDashboard = do
    maybeSession <- liftIO loadSession
    case maybeSession of
        Left _           -> pure (Left SessionAbsent)
        Right Nothing    -> pure (Left SessionAbsent)
        Right (Just uid) -> do
            tournaments <- listTournamentsByOwner uid
            pure (Right (buildTournamentOverview tournaments))