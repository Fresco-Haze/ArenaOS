module Domain.Audit
  ( AuditOperation(..)
  , AuditEvent(..)
  ) where

import Domain.Ids (UserId)
import Domain.Role (Role)
import Domain.User (AccountStatus)
import Data.Time (UTCTime)

data AuditOperation
  = RoleGranted Role
  | RoleRevoked Role
  | AccountStatusChanged
      { auditPreviousStatus :: AccountStatus
      , auditNewStatus      :: AccountStatus
      }
  deriving (Show, Eq)

data AuditEvent = AuditEvent
  { auditActor     :: UserId
  , auditEntity    :: UserId
  , auditOperation :: AuditOperation
  , auditTime      :: UTCTime
  } deriving (Show, Eq)