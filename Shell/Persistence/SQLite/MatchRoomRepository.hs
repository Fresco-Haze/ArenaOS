{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}

module Shell.Persistence.SQLite.MatchRoomRepository () where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import qualified Data.ByteString as BS
import Data.Text (Text)
import Database.SQLite.Simple (Only(..), execute, query, lastInsertRowId)

import Domain.Ids (UserId(..), TournamentId(..))
import Domain.Match (MatchId(..))
import Shell.Persistence.Port (MatchRoomRepository(..))
import Shell.Persistence.SQLite.Connection (SQLiteEnv(..), SQLiteM)

instance MatchRoomRepository SQLiteM where

  addReferee :: TournamentId -> UserId -> SQLiteM ()
  addReferee (TournamentId tid) (UserId uid) = do
    conn <- asks envConnection
    liftIO $ execute conn
      "INSERT OR IGNORE INTO tournament_referees (tournament_id, user_id) VALUES (?, ?)"
      (tid, uid)

  removeReferee :: TournamentId -> UserId -> SQLiteM ()
  removeReferee (TournamentId tid) (UserId uid) = do
    conn <- asks envConnection
    liftIO $ execute conn
      "DELETE FROM tournament_referees WHERE tournament_id = ? AND user_id = ?"
      (tid, uid)

  listReferees :: TournamentId -> SQLiteM [UserId]
  listReferees (TournamentId tid) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn
        "SELECT user_id FROM tournament_referees WHERE tournament_id = ? ORDER BY rowid"
        (Only tid)
       :: IO [Only Int])
    pure [ UserId u | Only u <- rows ]

  setLobbyCode :: MatchId -> UserId -> Text -> SQLiteM ()
  setLobbyCode (MatchId mid) (UserId uid) code = do
    conn <- asks envConnection
    liftIO $ execute conn
      "INSERT INTO match_lobby_codes (match_id, code, set_by, updated_at) \
      \VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now')) \
      \ON CONFLICT(match_id) DO UPDATE SET code = excluded.code, set_by = excluded.set_by, updated_at = excluded.updated_at"
      (mid, code, uid)

  getLobbyCode :: MatchId -> SQLiteM (Maybe Text)
  getLobbyCode (MatchId mid) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn "SELECT code FROM match_lobby_codes WHERE match_id = ?" (Only mid)
       :: IO [Only Text])
    pure (case rows of
            (Only c : _) -> Just c
            []           -> Nothing)

  addEvidence :: MatchId -> UserId -> Maybe Text -> BS.ByteString -> SQLiteM Int
  addEvidence (MatchId mid) (UserId uid) note bytes = do
    conn <- asks envConnection
    liftIO $ do
      execute conn
        "INSERT INTO match_evidence (match_id, uploaded_by, note, image, created_at) \
        \VALUES (?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))"
        (mid, uid, note, bytes)
      n <- lastInsertRowId conn
      pure (fromIntegral n)

  listEvidence :: MatchId -> SQLiteM [(Int, UserId, Maybe Text, Text)]
  listEvidence (MatchId mid) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn
        "SELECT id, uploaded_by, note, created_at FROM match_evidence WHERE match_id = ? ORDER BY id"
        (Only mid)
       :: IO [(Int, Int, Maybe Text, Text)])
    pure [ (i, UserId u, n, c) | (i, u, n, c) <- rows ]

  getEvidenceImage :: MatchId -> Int -> SQLiteM (Maybe BS.ByteString)
  getEvidenceImage (MatchId mid) eid = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn "SELECT image FROM match_evidence WHERE match_id = ? AND id = ?" (mid, eid)
       :: IO [Only BS.ByteString])
    pure (case rows of
            (Only b : _) -> Just b
            []           -> Nothing)

  getEvidenceUploader :: MatchId -> Int -> SQLiteM (Maybe UserId)
  getEvidenceUploader (MatchId mid) eid = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn "SELECT uploaded_by FROM match_evidence WHERE match_id = ? AND id = ?" (mid, eid)
       :: IO [Only Int])
    pure (case rows of
            (Only u : _) -> Just (UserId u)
            []           -> Nothing)

  deleteEvidence :: MatchId -> Int -> SQLiteM ()
  deleteEvidence (MatchId mid) eid = do
    conn <- asks envConnection
    liftIO $ execute conn "DELETE FROM match_evidence WHERE match_id = ? AND id = ?" (mid, eid)

  countEvidence :: MatchId -> SQLiteM Int
  countEvidence (MatchId mid) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn "SELECT COUNT(*) FROM match_evidence WHERE match_id = ?" (Only mid)
       :: IO [Only Int])
    pure (case rows of
            (Only n : _) -> n
            []           -> 0)

  addMatchMessage :: MatchId -> Maybe UserId -> Text -> Text -> SQLiteM Int
  addMatchMessage (MatchId mid) mUser kind msg = do
    conn <- asks envConnection
    let uidM = case mUser of
                 Just (UserId u) -> Just u
                 Nothing         -> Nothing
    liftIO $ do
      execute conn
        "INSERT INTO match_messages (match_id, user_id, kind, body, created_at) \
        \VALUES (?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))"
        (mid, uidM, kind, msg)
      n <- lastInsertRowId conn
      pure (fromIntegral n)

  listMatchMessages :: MatchId -> Int -> SQLiteM [(Int, Maybe UserId, Text, Text, Text)]
  listMatchMessages (MatchId mid) after = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn
        "SELECT id, user_id, kind, body, created_at FROM match_messages \
        \WHERE match_id = ? AND id > ? ORDER BY id LIMIT 200"
        (mid, after)
       :: IO [(Int, Maybe Int, Text, Text, Text)])
    pure [ (i, fmap UserId u, k, b, at) | (i, u, k, b, at) <- rows ]
