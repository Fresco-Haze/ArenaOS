module Application.UseCases.GetAdministratorDashboard
  ( GetAdministratorDashboardError(..)
  , getAdministratorDashboard
  ) where

import Domain.Ids (UserId)
import Shell.Persistence.Port (TournamentRepository(..), RoleRepository(..))
import Application.Internal.Authorization (AuthorizationError(..), requireAdministrator)
import Application.Internal.TournamentOverview (TournamentOverview, buildTournamentOverview)

data GetAdministratorDashboardError
    = Unauthorized AuthorizationError
    deriving (Eq, Show)

getAdministratorDashboard
    :: (RoleRepository m, TournamentRepository m)
    => UserId
    -> m (Either GetAdministratorDashboardError TournamentOverview)
getAdministratorDashboard actorId = do
    actorRoles <- getRoles actorId
    case requireAdministrator actorRoles of
        Left err -> pure (Left (Unauthorized err))
        Right () -> do
            tournaments <- listAllTournaments
            pure (Right (buildTournamentOverview tournaments))