{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}

module Shell.Persistence.SQLite.AvatarRepository () where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import qualified Data.ByteString as BS
import Database.SQLite.Simple (Only(..), execute, query)

import Domain.Ids (UserId(..))
import Shell.Persistence.Port (AvatarRepository(..))
import Shell.Persistence.SQLite.Connection (SQLiteEnv(..), SQLiteM)

instance AvatarRepository SQLiteM where

  setAvatar :: UserId -> BS.ByteString -> SQLiteM ()
  setAvatar (UserId uidInt) bytes = do
    conn <- asks envConnection
    liftIO $ execute conn
      "INSERT INTO user_avatars (user_id, image, updated_at) \
      \VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now')) \
      \ON CONFLICT(user_id) DO UPDATE SET image = excluded.image, updated_at = excluded.updated_at"
      (uidInt, bytes)

  getAvatar :: UserId -> SQLiteM (Maybe BS.ByteString)
  getAvatar (UserId uidInt) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn "SELECT image FROM user_avatars WHERE user_id = ?" (Only uidInt)
       :: IO [Only BS.ByteString])
    pure (case rows of
            (Only b : _) -> Just b
            []           -> Nothing)

  hasAvatar :: UserId -> SQLiteM Bool
  hasAvatar (UserId uidInt) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn "SELECT 1 FROM user_avatars WHERE user_id = ?" (Only uidInt)
       :: IO [Only Int])
    pure (not (null rows))

  deleteAvatar :: UserId -> SQLiteM ()
  deleteAvatar (UserId uidInt) = do
    conn <- asks envConnection
    liftIO $ execute conn "DELETE FROM user_avatars WHERE user_id = ?" (Only uidInt)