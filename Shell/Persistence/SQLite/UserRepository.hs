 {-# LANGUAGE OverloadedStrings #-}
 {-# LANGUAGE InstanceSigs #-}
 {-# LANGUAGE GeneralizedNewtypeDeriving #-}    
module Shell.Persistence.SQLite.UserRepository () where

import Control.Monad.Reader (asks, liftIO)
import Database.SQLite.Simple (execute, query, Only(..), lastInsertRowId)
import Data.Text (Text)
import Control.Monad (when)
import Database.SQLite.Simple (execute, query, lastInsertRowId, Only(..), changes)

import Domain.Ids (UserId(..))
import Domain.User (User(..),Username(..), Email(..), PasswordHash(..), AccountStatus(..))
import Shell.Persistence.SQLite.Connection (SQLiteM, envConnection)
import Shell.Persistence.SQLite.Error (PersistenceError(..))
import Shell.Persistence.Port (UserRepository(..), NewUser(..))
import Control.Exception (throwIO)

accountStatusToText :: AccountStatus -> String
accountStatusToText Active      = "Active"
accountStatusToText Suspended   = "Suspended"
accountStatusToText Deactivated = "Deactivated"

textToAccountStatus :: String -> IO AccountStatus
textToAccountStatus "Active"      = pure Active
textToAccountStatus "Suspended"   = pure Suspended
textToAccountStatus "Deactivated" = pure Deactivated
textToAccountStatus other =
  throwIO (StorageFailure ("Unknown account status in storage: " ++ other))

instance UserRepository SQLiteM where
  createUser :: NewUser -> SQLiteM UserId
  createUser nu = do
    conn <- asks envConnection
    liftIO $ execute conn
      "INSERT INTO users (username, email, password_hash, created_at) VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))"
      ( unUsername (newUserUsername nu)
      , unEmail (newUserEmail nu)
      , unPasswordHash (newUserPasswordHash nu)
      )
    rowId <- liftIO $ lastInsertRowId conn
    pure (UserId (fromIntegral rowId))

  findUserByUsername :: Username -> SQLiteM (Maybe User)
  findUserByUsername (Username uname) = do
    conn <- asks envConnection
    rows <- liftIO  (query conn
      "SELECT id, username, email, password_hash, account_status FROM users WHERE username = ? COLLATE NOCASE"
      (Only uname)
      :: IO [(Int, Text, Text, Text, String)])
    case rows of
      [] -> pure Nothing
      [(i, un, em, ph, statusText)] -> do
        status <- liftIO $ textToAccountStatus statusText
        pure $ Just User
          { userId       = UserId i
          , username     = Username un
          , email        = Email em
          , passwordHash = PasswordHash ph
          , accountStatus = status
        }
      _ -> liftIO $ throwIO (StorageFailure "Multiple users with same username")

  findUserByEmail :: Email -> SQLiteM (Maybe User)
  findUserByEmail (Email em') = do
    conn <- asks envConnection
    rows <- liftIO $ (query conn
      "SELECT id, username, email, password_hash, account_status FROM users WHERE lower(email) = lower(?)"
      (Only em')
      :: IO [(Int, Text, Text, Text, String)])
    case rows of
      [] -> pure Nothing
      [(i, un, em, ph, statusText)] -> do
        status <- liftIO $ textToAccountStatus statusText
        pure $ Just User
          { userId       = UserId i
          , username     = Username un
          , email        = Email em
          , passwordHash = PasswordHash ph
          , accountStatus = status
        }

  
      _ -> liftIO $ throwIO (StorageFailure "Multiple users with same email")

  findUserById :: UserId -> SQLiteM (Maybe User)          
  findUserById (UserId uid) = do
    conn <- asks envConnection
    rows <- liftIO $ (query conn
      "SELECT id, username, email, password_hash, account_status FROM users WHERE id = ?"
      (Only uid)
      :: IO [(Int, Text, Text, Text, String)])
    case rows of
      [] -> pure Nothing
      [(i, un, em, ph, statusText)] -> do
        status <- liftIO $ textToAccountStatus statusText
        pure $ Just User
          { userId       = UserId i
          , username     = Username un
          , email        = Email em
          , passwordHash = PasswordHash ph
          , accountStatus = status
        }
      _ -> liftIO $ throwIO (StorageFailure "Multiple users with same id")

  updatePasswordHash :: UserId -> PasswordHash -> SQLiteM ()   -- ADD THIS
  updatePasswordHash (UserId uid) newHash = do
    conn <- asks envConnection
    liftIO $ execute conn
      "UPDATE users SET password_hash = ? WHERE id = ?"
      (unPasswordHash newHash, uid)
    n <- liftIO $ changes conn
    when (n == 0) $
      liftIO $ throwIO (NotFound ("User not found: " ++ show uid))

  updateUsername :: UserId -> Username -> SQLiteM ()
  updateUsername (UserId uid) (Username uname) = do
    conn <- asks envConnection
    liftIO $ execute conn
      "UPDATE users SET username = ? WHERE id = ?"
      (uname, uid)
    n <- liftIO $ changes conn
    when (n == 0) $
      liftIO $ throwIO (NotFound ("User not found: " ++ show uid))

  updateEmail :: UserId -> Email -> SQLiteM ()
  updateEmail (UserId uid) (Email em) = do
    conn <- asks envConnection
    liftIO $ execute conn
      "UPDATE users SET email = ? WHERE id = ?"
      (em, uid)
    n <- liftIO $ changes conn
    when (n == 0) $
      liftIO $ throwIO (NotFound ("User not found: " ++ show uid))

  updateAccountStatus :: UserId -> AccountStatus -> SQLiteM ()
  updateAccountStatus (UserId uid) status = do
    conn <- asks envConnection
    liftIO $ execute conn
      "UPDATE users SET account_status = ? WHERE id = ?"
      (accountStatusToText status, uid)
    n <- liftIO $ changes conn
    when (n == 0) $
      liftIO $ throwIO (NotFound ("User not found: " ++ show uid))

  setFullName :: UserId -> Maybe Text -> SQLiteM ()
  setFullName (UserId uid) mName = do
    conn <- asks envConnection
    liftIO $ execute conn
      "UPDATE users SET full_name = ? WHERE id = ?"
      (mName, uid)
    n <- liftIO $ changes conn
    when (n == 0) $
      liftIO $ throwIO (NotFound ("User not found: " ++ show uid))

  getFullName :: UserId -> SQLiteM (Maybe Text)
  getFullName (UserId uid) = do
    conn <- asks envConnection
    rows <- liftIO (query conn
      "SELECT full_name FROM users WHERE id = ?"
      (Only uid)
      :: IO [Only (Maybe Text)])
    pure $ case rows of
      (Only n : _) -> n
      []           -> Nothing

  setBio :: UserId -> Maybe Text -> SQLiteM ()
  setBio (UserId uid) mBio = do
    conn <- asks envConnection
    liftIO $ execute conn
      "UPDATE users SET bio = ? WHERE id = ?"
      (mBio, uid)
    n <- liftIO $ changes conn
    when (n == 0) $
      liftIO $ throwIO (NotFound ("User not found: " ++ show uid))

  getBio :: UserId -> SQLiteM (Maybe Text)
  getBio (UserId uid) = do
    conn <- asks envConnection
    rows <- liftIO (query conn
      "SELECT bio FROM users WHERE id = ?"
      (Only uid)
      :: IO [Only (Maybe Text)])
    pure $ case rows of
      (Only b : _) -> b
      []           -> Nothing

  getMemberSince :: UserId -> SQLiteM (Maybe Text)
  getMemberSince (UserId uid) = do
    conn <- asks envConnection
    rows <- liftIO (query conn
      "SELECT created_at FROM users WHERE id = ?"
      (Only uid)
      :: IO [Only (Maybe Text)])
    pure $ case rows of
      (Only s : _) -> s
      []           -> Nothing

  createPasswordReset :: UserId -> Text -> Int -> SQLiteM Int
  createPasswordReset (UserId uid) secretHash expiresAt = do
    conn <- asks envConnection
    liftIO $ execute conn
      "INSERT INTO password_resets (user_id, secret_hash, expires_at) VALUES (?, ?, ?)"
      (uid, secretHash, expiresAt)
    rowId <- liftIO $ lastInsertRowId conn
    pure (fromIntegral rowId)

  findPasswordReset :: Int -> SQLiteM (Maybe (UserId, Text, Int, Bool))
  findPasswordReset rid = do
    conn <- asks envConnection
    rows <- liftIO (query conn
      "SELECT user_id, secret_hash, expires_at, used_at IS NOT NULL FROM password_resets WHERE id = ?"
      (Only rid)
      :: IO [(Int, Text, Int, Int)])
    pure $ case rows of
      ((u, h, e, used) : _) -> Just (UserId u, h, e, used /= 0)
      []                    -> Nothing

  consumePasswordResets :: UserId -> SQLiteM ()
  consumePasswordResets (UserId uid) = do
    conn <- asks envConnection
    liftIO $ execute conn
      "UPDATE password_resets SET used_at = 1 WHERE user_id = ? AND used_at IS NULL"
      (Only uid)

  
