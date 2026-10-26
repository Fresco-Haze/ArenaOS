{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}

module Shell.Persistence.SQLite.AvatarRepository () where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import qualified Data.ByteString as BS
import Database.SQLite.Simple (Only(..), execute, query)

import Domain.Ids (UserId(..), TournamentId(..))
import Shell.Persistence.Port (AvatarRepository(..), BannerRepository(..))
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

instance BannerRepository SQLiteM where

  setBanner :: TournamentId -> BS.ByteString -> SQLiteM ()
  setBanner (TournamentId tidInt) bytes = do
    conn <- asks envConnection
    liftIO $ execute conn
      "INSERT INTO tournament_banners (tournament_id, image, updated_at) \
      \VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now')) \
      \ON CONFLICT(tournament_id) DO UPDATE SET image = excluded.image, updated_at = excluded.updated_at"
      (tidInt, bytes)

  getBanner :: TournamentId -> SQLiteM (Maybe BS.ByteString)
  getBanner (TournamentId tidInt) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn "SELECT image FROM tournament_banners WHERE tournament_id = ?" (Only tidInt)
       :: IO [Only BS.ByteString])
    pure (case rows of
            (Only b : _) -> Just b
            []           -> Nothing)

  hasBanner :: TournamentId -> SQLiteM Bool
  hasBanner (TournamentId tidInt) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn "SELECT 1 FROM tournament_banners WHERE tournament_id = ?" (Only tidInt)
       :: IO [Only Int])
    pure (not (null rows))

  deleteBanner :: TournamentId -> SQLiteM ()
  deleteBanner (TournamentId tidInt) = do
    conn <- asks envConnection
    liftIO $ execute conn "DELETE FROM tournament_banners WHERE tournament_id = ?" (Only tidInt)