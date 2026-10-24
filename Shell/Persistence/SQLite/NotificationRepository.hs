{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}

module Shell.Persistence.SQLite.NotificationRepository () where

import Control.Exception (throwIO)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Database.SQLite.Simple (Only(..), execute, query)

import Domain.Ids (UserId(..), TournamentId(..))
import Domain.Notification (Notification(..), NotificationKind(..))
import Shell.Persistence.Port (NotificationRepository(..))
import Shell.Persistence.SQLite.Connection (SQLiteEnv(..), SQLiteM)
import Shell.Persistence.SQLite.Error (PersistenceError(..))

kindToText :: NotificationKind -> String
kindToText NoteJoinRequested     = "JoinRequested"
kindToText NoteRequestApproved   = "RequestApproved"
kindToText NoteRequestDeclined   = "RequestDeclined"
kindToText NoteTournamentStarted = "TournamentStarted"

textToKind :: String -> IO NotificationKind
textToKind "JoinRequested"     = pure NoteJoinRequested
textToKind "RequestApproved"   = pure NoteRequestApproved
textToKind "RequestDeclined"   = pure NoteRequestDeclined
textToKind "TournamentStarted" = pure NoteTournamentStarted
textToKind other =
  throwIO (StorageFailure ("Unknown notification kind in storage: " ++ other))

instance NotificationRepository SQLiteM where

  addNotification :: UserId -> NotificationKind -> TournamentId -> Maybe String -> SQLiteM ()
  addNotification (UserId uidInt) kind (TournamentId tidInt) detail = do
    conn <- asks envConnection
    liftIO $ execute conn
      "INSERT INTO notifications (user_id, kind, tournament_id, detail, created_at) \
      \VALUES (?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))"
      (uidInt, kindToText kind, tidInt, detail)

  listNotifications :: UserId -> Int -> SQLiteM [Notification]
  listNotifications (UserId uidInt) limitN = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn
        "SELECT n.id, n.kind, n.tournament_id, t.name, n.detail, n.created_at, n.read_at IS NOT NULL \
        \FROM notifications n JOIN tournaments t ON t.id = n.tournament_id \
        \WHERE n.user_id = ? ORDER BY n.id DESC LIMIT ?"
        (uidInt, limitN)
       :: IO [(Int, String, Int, String, Maybe String, String, Int)])
    liftIO (mapM decodeRow rows)
   where
    decodeRow (nid, k, tid, tname, det, at, rd) = do
      kind <- textToKind k
      pure Notification
        { notificationId             = nid
        , notificationKind           = kind
        , notificationTournamentId   = TournamentId tid
        , notificationTournamentName = tname
        , notificationDetail         = det
        , notificationAt             = at
        , notificationRead           = rd /= 0
        }

  countUnreadNotifications :: UserId -> SQLiteM Int
  countUnreadNotifications (UserId uidInt) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn
        "SELECT COUNT(*) FROM notifications WHERE user_id = ? AND read_at IS NULL"
        (Only uidInt)
       :: IO [Only Int])
    pure (case rows of
            (Only n : _) -> n
            []           -> 0)

  markAllNotificationsRead :: UserId -> SQLiteM ()
  markAllNotificationsRead (UserId uidInt) = do
    conn <- asks envConnection
    liftIO $ execute conn
      "UPDATE notifications SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') \
      \WHERE user_id = ? AND read_at IS NULL"
      (Only uidInt)