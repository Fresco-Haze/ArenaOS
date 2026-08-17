{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE InstanceSigs #-}

module Shell.Persistence.SQLite.RoleRepository () where

import Control.Monad.Reader (asks, liftIO)
import Control.Monad (when)
import Database.SQLite.Simple (execute, query, Only(..), changes)
import Control.Exception (throwIO)

import Domain.Role (Role(..))
import Domain.Ids (UserId(..))
import Shell.Persistence.SQLite.Connection (SQLiteM, envConnection)
import Shell.Persistence.SQLite.Error (PersistenceError(..))
import Shell.Persistence.Port (RoleRepository(..))

roleToText :: Role -> String
roleToText Administrator = "Administrator"

textToRole :: String -> IO Role
textToRole "Administrator" = pure Administrator
textToRole other =
  throwIO (StorageFailure ("Unknown role in storage: " ++ other))

instance RoleRepository SQLiteM where
  insertRoleMembership :: UserId -> Role -> SQLiteM ()
  insertRoleMembership (UserId uid) role = do
    conn <- asks envConnection
    liftIO $ execute conn
      "INSERT INTO user_roles (user_id, role) VALUES (?, ?)"
      (uid, roleToText role)

  deleteRoleMembership :: UserId -> Role -> SQLiteM ()
  deleteRoleMembership (UserId uid) role = do
    conn <- asks envConnection
    liftIO $ execute conn
      "DELETE FROM user_roles WHERE user_id = ? AND role = ?"
      (uid, roleToText role)
    n <- liftIO $ changes conn
    when (n == 0) $
      liftIO $ throwIO (NotFound
        ("Role not assigned: user " ++ show uid ++ ", role " ++ roleToText role))

  getRoles :: UserId -> SQLiteM [Role]
  getRoles (UserId uid) = do
    conn <- asks envConnection
    rows <- liftIO (query conn
      "SELECT role FROM user_roles WHERE user_id = ?"
      (Only uid)
      :: IO [Only String])
    liftIO $ mapM (\(Only r) -> textToRole r) rows

  listRoleHolders :: Role -> SQLiteM [UserId]
  listRoleHolders role = do
    conn <- asks envConnection
    rows <- liftIO (query conn
      "SELECT user_id FROM user_roles WHERE role = ?"
      (Only (roleToText role))
      :: IO [Only Int])
    pure (map (\(Only uid) -> UserId uid) rows)