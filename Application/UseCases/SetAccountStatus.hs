module Application.UseCases.SetAccountStatus
  ( SetAccountStatusRequest(..)
  , SetAccountStatusError(..)
  , setAccountStatus
  ) where

import Domain.User (User(..), AccountStatus(..))
import Domain.Ids (UserId)
import Shell.Persistence.Port (UserRepository(..), RoleRepository(..), Transactional(..), AuditLogRepository(..))
import Application.Internal.Authorization (AuthorizationError(..), requireAdministrator)
import Domain.Audit (AuditEvent(..), AuditOperation(..))
import Control.Monad.IO.Class (liftIO, MonadIO)
import Data.Time (getCurrentTime)


data SetAccountStatusRequest = SetAccountStatusRequest
    { statusActorId :: UserId
    , statusUserId  :: UserId
    , statusNew     :: AccountStatus
    }
    deriving (Eq, Show)

data SetAccountStatusError
    = StatusUserNotFound
    | Unauthorized AuthorizationError
    deriving (Eq, Show)

setAccountStatus
    :: (Monad m, UserRepository m, RoleRepository m, AuditLogRepository m, Transactional m, MonadIO m)
    => SetAccountStatusRequest
    -> m (Either SetAccountStatusError ())
setAccountStatus req = withTxN $ do
    actorRoles <- getRoles (statusActorId req)
    case requireAdministrator actorRoles of
        Left err -> pure (Left (Unauthorized err))
        Right () -> do
            maybeUser <- findUserById (statusUserId req)
            case maybeUser of
                Nothing -> pure (Left StatusUserNotFound)
                Just user -> do
                    let prevStatus = accountStatus user
                    updateAccountStatus (statusUserId req) (statusNew req)
                    now <- liftIO getCurrentTime
                    recordAuditEvent AuditEvent
                      { auditActor = statusActorId req, auditEntity = statusUserId req
                      , auditOperation = AccountStatusChanged prevStatus (statusNew req)
                      , auditTime = now }
                    pure (Right ())