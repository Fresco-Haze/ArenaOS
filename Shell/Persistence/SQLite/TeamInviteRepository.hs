{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}

module Shell.Persistence.SQLite.TeamInviteRepository () where

import Control.Exception (throwIO)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Database.SQLite.Simple (Only(..), execute, query)

import Domain.Ids (UserId(..))
import Domain.Participant (PlayerName(..), TeamName(..))
import Domain.TeamInvite (TeamInviteStatus(..))
import Shell.Persistence.Port (TeamInviteRepository(..))
import Shell.Persistence.SQLite.Connection (SQLiteEnv(..), SQLiteM)
import Shell.Persistence.SQLite.Error (PersistenceError(..))

statusToText :: TeamInviteStatus -> String
statusToText InvitePending  = "Pending"
statusToText InviteAccepted = "Accepted"
statusToText InviteDeclined = "Declined"

textToStatus :: String -> IO TeamInviteStatus
textToStatus "Pending"  = pure InvitePending
textToStatus "Accepted" = pure InviteAccepted
textToStatus "Declined" = pure InviteDeclined
textToStatus other =
  throwIO (StorageFailure ("Unknown team invite status in storage: " ++ other))

instance TeamInviteRepository SQLiteM where

  createTeamInvite :: TeamName -> UserId -> UserId -> SQLiteM ()
  createTeamInvite (TeamName tname) (UserId invitee) (UserId inviter) = do
    conn <- asks envConnection
    liftIO $ execute conn
      "INSERT INTO team_invites (team_id, user_id, invited_by, status, created_at) \
      \SELECT id, ?, ?, 'Pending', strftime('%Y-%m-%dT%H:%M:%SZ', 'now') FROM teams WHERE name = ? COLLATE NOCASE \
      \ON CONFLICT(team_id, user_id) DO UPDATE SET status = 'Pending', invited_by = excluded.invited_by"
      (invitee, inviter, tname)

  setTeamInviteStatus :: TeamName -> UserId -> TeamInviteStatus -> SQLiteM ()
  setTeamInviteStatus (TeamName tname) (UserId uid) st = do
    conn <- asks envConnection
    liftIO $ execute conn
      "UPDATE team_invites SET status = ? WHERE user_id = ? \
      \AND team_id IN (SELECT id FROM teams WHERE name = ? COLLATE NOCASE)"
      (statusToText st, uid, tname)

  getTeamInvite :: TeamName -> UserId -> SQLiteM (Maybe TeamInviteStatus)
  getTeamInvite (TeamName tname) (UserId uid) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn
        "SELECT i.status FROM team_invites i JOIN teams t ON t.id = i.team_id \
        \WHERE t.name = ? COLLATE NOCASE AND i.user_id = ?"
        (tname, uid)
       :: IO [Only String])
    case rows of
      []           -> pure Nothing
      (Only s : _) -> Just <$> liftIO (textToStatus s)

  deleteTeamInvite :: TeamName -> UserId -> SQLiteM ()
  deleteTeamInvite (TeamName tname) (UserId uid) = do
    conn <- asks envConnection
    liftIO $ execute conn
      "DELETE FROM team_invites WHERE user_id = ? \
      \AND team_id IN (SELECT id FROM teams WHERE name = ? COLLATE NOCASE)"
      (uid, tname)

  listPendingTeamInvites :: TeamName -> SQLiteM [UserId]
  listPendingTeamInvites (TeamName tname) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn
        "SELECT i.user_id FROM team_invites i JOIN teams t ON t.id = i.team_id \
        \WHERE t.name = ? COLLATE NOCASE AND i.status = 'Pending' ORDER BY i.id"
        (Only tname)
       :: IO [Only Int])
    pure [ UserId u | Only u <- rows ]

  listInvitesForUser :: UserId -> SQLiteM [(TeamName, UserId)]
  listInvitesForUser (UserId uid) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn
        "SELECT t.name, i.invited_by FROM team_invites i JOIN teams t ON t.id = i.team_id \
        \WHERE i.user_id = ? AND i.status = 'Pending' ORDER BY i.id DESC"
        (Only uid)
       :: IO [(String, Int)])
    pure [ (TeamName n, UserId by) | (n, by) <- rows ]

  listTeamNamesByMember :: PlayerName -> SQLiteM [TeamName]
  listTeamNamesByMember (PlayerName pname) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn
        "SELECT t.name FROM teams t \
        \JOIN team_members m ON m.team_id = t.id \
        \JOIN players p ON p.id = m.player_id \
        \WHERE p.name = ? COLLATE NOCASE ORDER BY t.name COLLATE NOCASE"
        (Only pname)
       :: IO [Only String])
    pure [ TeamName n | Only n <- rows ]