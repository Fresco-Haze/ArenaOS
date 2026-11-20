{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}

module Shell.Persistence.SQLite.NotificationRepository () where

import Control.Exception (throwIO)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Database.SQLite.Simple (Only(..), changes, execute, lastInsertRowId, query)

import Data.Text (Text)
import Domain.Announcement (Announcement(..))
import Domain.Ids (UserId(..), TournamentId(..))
import Domain.Notification (Notification(..), NotificationKind(..))
import Shell.Persistence.Port (AnnouncementRepository(..), NotificationRepository(..), PrizeSplitRepository(..))
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


-- Announcements live in this module for now; they can move to their own module later.
instance AnnouncementRepository SQLiteM where

  addAnnouncement :: TournamentId -> UserId -> Text -> SQLiteM Int
  addAnnouncement (TournamentId tidInt) (UserId uidInt) body = do
    conn <- asks envConnection
    liftIO $ do
      execute conn
        "INSERT INTO announcements (tournament_id, user_id, body, created_at) \
        \VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))"
        (tidInt, uidInt, body)
      fromIntegral <$> lastInsertRowId conn

  listAnnouncements :: TournamentId -> SQLiteM [Announcement]
  listAnnouncements (TournamentId tidInt) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn
        "SELECT id, body, created_at FROM announcements WHERE tournament_id = ? ORDER BY id DESC"
        (Only tidInt)
       :: IO [(Int, Text, String)])
    pure [ Announcement { announcementId = i, announcementBody = b, announcementAt = at } | (i, b, at) <- rows ]

  deleteAnnouncement :: TournamentId -> Int -> SQLiteM Bool
  deleteAnnouncement (TournamentId tidInt) aid = do
    conn <- asks envConnection
    liftIO $ do
      execute conn "DELETE FROM announcements WHERE id = ? AND tournament_id = ?" (aid, tidInt)
      (> 0) <$> changes conn


-- Prize splits live in this module for now, next to announcements.
instance PrizeSplitRepository SQLiteM where

  getPrizeSplit :: TournamentId -> SQLiteM [Int]
  getPrizeSplit (TournamentId tidInt) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn
        "SELECT percent FROM prize_splits WHERE tournament_id = ? ORDER BY place"
        (Only tidInt)
       :: IO [Only Int])
    pure [ pct | Only pct <- rows ]

  savePrizeSplit :: TournamentId -> [Int] -> SQLiteM ()
  savePrizeSplit (TournamentId tidInt) percents = do
    conn <- asks envConnection
    liftIO $ do
      execute conn "DELETE FROM prize_splits WHERE tournament_id = ?" (Only tidInt)
      mapM_
        (\(place, pct) ->
           execute conn
             "INSERT INTO prize_splits (tournament_id, place, percent) VALUES (?, ?, ?)"
             (tidInt, place, pct))
        (zip [1 :: Int ..] percents)

  clearPrizeSplit :: TournamentId -> SQLiteM ()
  clearPrizeSplit (TournamentId tidInt) = do
    conn <- asks envConnection
    liftIO $ execute conn "DELETE FROM prize_splits WHERE tournament_id = ?" (Only tidInt)