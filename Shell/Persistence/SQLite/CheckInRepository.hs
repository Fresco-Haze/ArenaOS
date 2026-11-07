{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}

-- Shell.Persistence.SQLite.CheckInRepository
-- Storage for check-in: an open/closed flag per tournament, and which registrations checked in.
module Shell.Persistence.SQLite.CheckInRepository () where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Database.SQLite.Simple (Only(..), execute, query)

import Domain.Ids (TournamentId(..))
import Domain.Registration (RegistrationId(..))
import Shell.Persistence.Port (CheckInRepository(..))
import Shell.Persistence.SQLite.Connection (SQLiteEnv(..), SQLiteM)

instance CheckInRepository SQLiteM where

  openCheckIn :: TournamentId -> SQLiteM ()
  openCheckIn (TournamentId tidInt) = do
    conn <- asks envConnection
    liftIO $ execute conn
      "INSERT INTO tournament_checkin (tournament_id, is_open) VALUES (?, 1) \
      \ON CONFLICT(tournament_id) DO UPDATE SET is_open = 1"
      (Only tidInt)

  closeCheckIn :: TournamentId -> SQLiteM ()
  closeCheckIn (TournamentId tidInt) = do
    conn <- asks envConnection
    liftIO $ execute conn
      "UPDATE tournament_checkin SET is_open = 0 WHERE tournament_id = ?"
      (Only tidInt)

  isCheckInOpen :: TournamentId -> SQLiteM Bool
  isCheckInOpen (TournamentId tidInt) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn "SELECT is_open FROM tournament_checkin WHERE tournament_id = ?" (Only tidInt)
       :: IO [Only Int])
    pure (case rows of
            (Only 1 : _) -> True
            _            -> False)

  setCheckedIn :: RegistrationId -> Bool -> SQLiteM ()
  setCheckedIn (RegistrationId ridInt) True = do
    conn <- asks envConnection
    liftIO $ execute conn
      "INSERT OR IGNORE INTO registration_checkins (registration_id, checked_in_at) \
      \VALUES (?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))"
      (Only ridInt)
  setCheckedIn (RegistrationId ridInt) False = do
    conn <- asks envConnection
    liftIO $ execute conn
      "DELETE FROM registration_checkins WHERE registration_id = ?"
      (Only ridInt)

  listCheckedIn :: TournamentId -> SQLiteM [RegistrationId]
  listCheckedIn (TournamentId tidInt) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn
        "SELECT rc.registration_id FROM registration_checkins rc \
        \JOIN registrations r ON r.id = rc.registration_id \
        \WHERE r.tournament_id = ? ORDER BY rc.registration_id"
        (Only tidInt)
       :: IO [Only Int])
    pure [ RegistrationId n | Only n <- rows ]