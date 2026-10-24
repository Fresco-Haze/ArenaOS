{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}

module Shell.Persistence.SQLite.JoinRequestRepository () where

import Control.Exception (throwIO)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Database.SQLite.Simple (Only(..), execute, query)

import Domain.Ids (UserId(..), TournamentId(..))
import Domain.JoinRequest (JoinRequestStatus(..))
import Shell.Persistence.Port (JoinRequestRepository(..))
import Shell.Persistence.SQLite.Connection (SQLiteEnv(..), SQLiteM)
import Shell.Persistence.SQLite.Error (PersistenceError(..))

statusToText :: JoinRequestStatus -> String
statusToText JoinPending  = "Pending"
statusToText JoinApproved = "Approved"
statusToText JoinDeclined = "Declined"

textToStatus :: String -> IO JoinRequestStatus
textToStatus "Pending"  = pure JoinPending
textToStatus "Approved" = pure JoinApproved
textToStatus "Declined" = pure JoinDeclined
textToStatus other =
  throwIO (StorageFailure ("Unknown join request status in storage: " ++ other))

instance JoinRequestRepository SQLiteM where

  getJoinRequest :: TournamentId -> UserId -> SQLiteM (Maybe JoinRequestStatus)
  getJoinRequest (TournamentId tidInt) (UserId uidInt) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn
        "SELECT status FROM join_requests WHERE tournament_id = ? AND user_id = ?"
        (tidInt, uidInt)
       :: IO [Only String])
    case rows of
      []           -> pure Nothing
      (Only s : _) -> Just <$> liftIO (textToStatus s)

  saveJoinRequest :: TournamentId -> UserId -> JoinRequestStatus -> SQLiteM ()
  saveJoinRequest (TournamentId tidInt) (UserId uidInt) st = do
    conn <- asks envConnection
    liftIO $ execute conn
      "INSERT INTO join_requests (tournament_id, user_id, status) VALUES (?, ?, ?) \
      \ON CONFLICT(tournament_id, user_id) DO UPDATE SET status = excluded.status"
      (tidInt, uidInt, statusToText st)

  deleteJoinRequest :: TournamentId -> UserId -> SQLiteM ()
  deleteJoinRequest (TournamentId tidInt) (UserId uidInt) = do
    conn <- asks envConnection
    liftIO $ execute conn
      "DELETE FROM join_requests WHERE tournament_id = ? AND user_id = ?"
      (tidInt, uidInt)

  listJoinRequests :: TournamentId -> SQLiteM [(UserId, JoinRequestStatus)]
  listJoinRequests (TournamentId tidInt) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn
        "SELECT user_id, status FROM join_requests WHERE tournament_id = ? ORDER BY id"
        (Only tidInt)
       :: IO [(Int, String)])
    liftIO (mapM (\(u, s) -> do { st <- textToStatus s; pure (UserId u, st) }) rows)