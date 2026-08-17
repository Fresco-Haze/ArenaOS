module Application.UseCases.RevokeRole
  ( RevokeRoleError(..)
  , revokeRole
  ) where

import Domain.Ids (UserId)
import Domain.Role (Role(..))
import Shell.Persistence.Port (RoleRepository(..), Transactional(..))
import Application.Internal.Authorization (AuthorizationError(..), requireAdministrator)
import Domain.Audit (AuditEvent(..), AuditOperation(..))
import Control.Monad.IO.Class (liftIO, MonadIO)
import Data.Time (getCurrentTime)
import Shell.Persistence.Port (AuditLogRepository(..))

data RevokeRoleError
  = RoleNotAssigned
  | CannotRevokeLastAdministrator
  | Unauthorized AuthorizationError
  deriving (Eq, Show)

-- ROLE-AUTH-002: the system must reject any revocation that would
-- leave zero Administrators platform-wide. This is a system-wide
-- invariant, not a per-user one -- it cannot be expressed by
-- requireAdministrator (which only answers "is this actor an
-- Administrator", not "would this leave the system with none"), so
-- it lives here rather than in the pure Authorization helper.
--
-- This check is specifically a consequence of Administrator's
-- self-referential grant/revoke authority (ROLE-AUTH-001) -- it is
-- NOT a general "every role's last holder is protected" law. If a
-- future role's management authority ever comes from a *different*
-- role, this check would not automatically apply to it.
revokeRole
  :: (RoleRepository m, Transactional m, AuditLogRepository m, MonadIO m)
  => UserId -> UserId -> Role -> m (Either RevokeRoleError ())
revokeRole actorId targetId role = withTxN $ do
  actorRoles <- getRoles actorId
  case requireAdministrator actorRoles of
    Left err -> pure (Left (Unauthorized err))
    Right () -> do
      targetRoles <- getRoles targetId
      if role `notElem` targetRoles
        then pure (Left RoleNotAssigned)
        else do
          holders <- listRoleHolders role
          if length holders <= 1
            then pure (Left CannotRevokeLastAdministrator)
            else do
              deleteRoleMembership targetId role
              now <- liftIO getCurrentTime
              recordAuditEvent AuditEvent
                { auditActor = actorId, auditEntity = targetId
                , auditOperation = RoleRevoked role, auditTime = now }
              pure (Right ())