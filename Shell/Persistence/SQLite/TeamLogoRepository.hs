{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}

module Shell.Persistence.SQLite.TeamLogoRepository () where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import qualified Data.ByteString as BS
import Database.SQLite.Simple (Only(..), execute, query)

import Domain.Participant (TeamName(..))
import Shell.Persistence.Port (TeamLogoRepository(..))
import Shell.Persistence.SQLite.Connection (SQLiteEnv(..), SQLiteM)

instance TeamLogoRepository SQLiteM where

  setTeamLogo :: TeamName -> BS.ByteString -> SQLiteM ()
  setTeamLogo (TeamName tname) bytes = do
    conn <- asks envConnection
    liftIO $ execute conn
      "INSERT INTO team_logos (team_id, image, updated_at) \
      \SELECT id, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') FROM teams WHERE name = ? COLLATE NOCASE \
      \ON CONFLICT(team_id) DO UPDATE SET image = excluded.image, updated_at = excluded.updated_at"
      (bytes, tname)

  getTeamLogo :: TeamName -> SQLiteM (Maybe BS.ByteString)
  getTeamLogo (TeamName tname) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn
        "SELECT l.image FROM team_logos l JOIN teams t ON t.id = l.team_id \
        \WHERE t.name = ? COLLATE NOCASE"
        (Only tname)
       :: IO [Only BS.ByteString])
    pure (case rows of
            (Only b : _) -> Just b
            []           -> Nothing)

  hasTeamLogo :: TeamName -> SQLiteM Bool
  hasTeamLogo (TeamName tname) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn
        "SELECT 1 FROM team_logos l JOIN teams t ON t.id = l.team_id \
        \WHERE t.name = ? COLLATE NOCASE"
        (Only tname)
       :: IO [Only Int])
    pure (not (null rows))

  deleteTeamLogo :: TeamName -> SQLiteM ()
  deleteTeamLogo (TeamName tname) = do
    conn <- asks envConnection
    liftIO $ execute conn
      "DELETE FROM team_logos WHERE team_id IN (SELECT id FROM teams WHERE name = ? COLLATE NOCASE)"
      (Only tname)