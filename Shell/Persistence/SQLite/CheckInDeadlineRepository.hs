{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}

module Shell.Persistence.SQLite.CheckInDeadlineRepository () where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Database.SQLite.Simple (Only(..), execute, query)

import Domain.Ids (TournamentId(..))
import Shell.Persistence.Port (CheckInDeadlineRepository(..))
import Shell.Persistence.SQLite.Connection (SQLiteEnv(..), SQLiteM)

instance CheckInDeadlineRepository SQLiteM where

  setCheckInDeadline :: TournamentId -> Maybe String -> SQLiteM ()
  setCheckInDeadline (TournamentId tid) Nothing = do
    conn <- asks envConnection
    liftIO $ execute conn
      "DELETE FROM tournament_checkin_deadline WHERE tournament_id = ?"
      (Only tid)
  setCheckInDeadline (TournamentId tid) (Just s) = do
    conn <- asks envConnection
    liftIO $ execute conn
      "INSERT INTO tournament_checkin_deadline (tournament_id, closes_at) VALUES (?, ?) \
      \ON CONFLICT(tournament_id) DO UPDATE SET closes_at = excluded.closes_at"
      (tid, s)

  getCheckInDeadline :: TournamentId -> SQLiteM (Maybe String)
  getCheckInDeadline (TournamentId tid) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn
        "SELECT closes_at FROM tournament_checkin_deadline WHERE tournament_id = ?"
        (Only tid)
       :: IO [Only String])
    pure (case rows of
            (Only s : _) -> Just s
            []           -> Nothing)