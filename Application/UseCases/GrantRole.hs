module Application.UseCases.GrantRole
  ( GrantRoleError(..)
  , grantRole
  ) where

import Domain.Ids (UserId)
import Domain.Role (Role(..))
import Shell.Persistence.Port (RoleRepository(..), Transactional(..))
import Application.Internal.Authorization (AuthorizationError(..), requireAdministrator)
import Domain.Audit (AuditEvent(..), AuditOperation(..))
import Control.Monad.IO.Class (liftIO, MonadIO)
import Data.Time (getCurrentTime)
import Shell.Persistence.Port (AuditLogRepository(..))

data GrantRoleError
  = RoleAlreadyAssigned
  | Unauthorized AuthorizationError
  deriving (Eq, Show)

-- ROLE-AUTH-001: an existing Administrator may grant Administrator to
-- another user. This is a judgment call, not directly specified by
-- frozen requirements -- justified because it's the only decision
-- that gives this mechanism a legitimate in-system caller after
-- bootstrap, since Administrator is currently the only persisted
-- role. Deliberately separate from ROLE-LIFECYCLE-001 (bootstrap
-- creates the initial authority; this governs subsequent management).
grantRole
  :: (RoleRepository m, Transactional m, AuditLogRepository m, MonadIO m)
  => UserId -> UserId -> Role -> m (Either GrantRoleError ())
grantRole actorId targetId role = withTxN $ do
  actorRoles <- getRoles actorId
  case requireAdministrator actorRoles of
    Left err -> pure (Left (Unauthorized err))
    Right () -> do
      targetRoles <- getRoles targetId
      if role `elem` targetRoles
        then pure (Left RoleAlreadyAssigned)
        else do
          insertRoleMembership targetId role
          now <- liftIO getCurrentTime
          recordAuditEvent AuditEvent
            { auditActor = actorId, auditEntity = targetId
            , auditOperation = RoleGranted role, auditTime = now }
          pure (Right ())

          
  

  