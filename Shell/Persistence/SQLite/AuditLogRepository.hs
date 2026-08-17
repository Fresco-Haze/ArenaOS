{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE InstanceSigs #-}

module Shell.Persistence.SQLite.AuditLogRepository () where

import Control.Monad.Reader (asks, liftIO)
import Control.Exception (throwIO)
import Database.SQLite.Simple (execute, query, Only(..))
import Data.Time (UTCTime)

import Domain.Audit (AuditEvent(..), AuditOperation(..))
import Domain.Ids (UserId(..))
import Domain.Role (Role(..))
import Domain.User (AccountStatus(..))
import Shell.Persistence.SQLite.Connection (SQLiteM, envConnection)
import Shell.Persistence.SQLite.Error (PersistenceError(..))
import Shell.Persistence.Port (AuditLogRepository(..))

-- Local text-conversion helpers, duplicated rather than shared across
-- repositories -- matches existing house style (each repository owns
-- its own conversions; no cross-repository coupling precedent exists).
roleToText :: Role -> String
roleToText Administrator = "Administrator"

textToRole :: String -> IO Role
textToRole "Administrator" = pure Administrator
textToRole other = throwIO (StorageFailure ("Unknown role in storage: " ++ other))

statusToText :: AccountStatus -> String
statusToText Active      = "Active"
statusToText Suspended   = "Suspended"
statusToText Deactivated = "Deactivated"

textToStatus :: String -> IO AccountStatus
textToStatus "Active"      = pure Active
textToStatus "Suspended"   = pure Suspended
textToStatus "Deactivated" = pure Deactivated
textToStatus other = throwIO (StorageFailure ("Unknown account status in storage: " ++ other))

operationToRow :: AuditOperation -> (String, Maybe String, Maybe String, Maybe String)
operationToRow (RoleGranted r) = ("RoleGranted", Just (roleToText r), Nothing, Nothing)
operationToRow (RoleRevoked r) = ("RoleRevoked", Just (roleToText r), Nothing, Nothing)
operationToRow (AccountStatusChanged prev new) =
  ("AccountStatusChanged", Nothing, Just (statusToText prev), Just (statusToText new))

rowToOperation :: String -> Maybe String -> Maybe String -> Maybe String -> IO AuditOperation
rowToOperation "RoleGranted" (Just r) _ _ = RoleGranted <$> textToRole r
rowToOperation "RoleRevoked" (Just r) _ _ = RoleRevoked <$> textToRole r
rowToOperation "AccountStatusChanged" _ (Just prev) (Just new) =
  AccountStatusChanged <$> textToStatus prev <*> textToStatus new
rowToOperation other _ _ _ =
  throwIO (StorageFailure ("Malformed audit_log row for operation: " ++ other))

instance AuditLogRepository SQLiteM where
  recordAuditEvent :: AuditEvent -> SQLiteM ()
  recordAuditEvent evt = do
    conn <- asks envConnection
    let UserId actorId  = auditActor evt
        UserId entityId = auditEntity evt
        (opText, roleText, prevText, newText) = operationToRow (auditOperation evt)
    liftIO $ execute conn
      "INSERT INTO audit_log (actor_id, entity_id, operation, role, previous_status, new_status, occurred_at) \
      \VALUES (?, ?, ?, ?, ?, ?, ?)"
      (actorId, entityId, opText, roleText, prevText, newText, auditTime evt)

  listAuditEventsForEntity :: UserId -> SQLiteM [AuditEvent]
  listAuditEventsForEntity (UserId entityId) = do
    conn <- asks envConnection
    rows <- liftIO (query conn
      "SELECT actor_id, entity_id, operation, role, previous_status, new_status, occurred_at \
      \FROM audit_log WHERE entity_id = ?"
      (Only entityId)
      :: IO [(Int, Int, String, Maybe String, Maybe String, Maybe String, UTCTime)])
    mapM decodeRow rows
   where
    decodeRow (actorId, entId, opText, roleText, prevText, newText, t) = do
      op <- liftIO $ rowToOperation opText roleText prevText newText
      pure AuditEvent
        { auditActor = UserId actorId, auditEntity = UserId entId
        , auditOperation = op, auditTime = t }