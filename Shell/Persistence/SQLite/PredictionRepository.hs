{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}

module Shell.Persistence.SQLite.PredictionRepository () where

import Control.Exception (throwIO)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.Int (Int64)
import Database.SQLite.Simple (execute, query, Only(..))

import Domain.Ids (TournamentId(..), UserId(..))
import Domain.Match (MatchId(..))
import Domain.Prediction (Pick(..))
import Shell.Persistence.Port (PredictionRepository(..))
import Shell.Persistence.SQLite.Connection (SQLiteEnv(..), SQLiteM)
import Shell.Persistence.SQLite.Error (PersistenceError(..))

pickToText :: Pick -> String
pickToText PickA = "A"
pickToText PickB = "B"
pickToText PickDraw = "Draw"

pickFromText :: String -> Maybe Pick
pickFromText "A" = Just PickA
pickFromText "B" = Just PickB
pickFromText "Draw" = Just PickDraw
pickFromText _ = Nothing

decodePick :: String -> IO Pick
decodePick s = case pickFromText s of
  Just p  -> pure p
  Nothing -> throwIO (StorageFailure ("Unknown prediction pick in storage: " ++ s))

instance PredictionRepository SQLiteM where

  savePrediction :: MatchId -> UserId -> Pick -> SQLiteM ()
  savePrediction (MatchId midInt) (UserId uidInt) pick = do
    conn <- asks envConnection
    liftIO $ execute conn
      "INSERT INTO predictions (match_id, user_id, pick, created_at) \
      \VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now')) \
      \ON CONFLICT(match_id, user_id) DO UPDATE SET \
      \  pick = excluded.pick, \
      \  created_at = excluded.created_at"
      (midInt, uidInt, pickToText pick)

  listUserPredictions :: TournamentId -> UserId -> SQLiteM [(MatchId, Pick)]
  listUserPredictions (TournamentId tidInt) (UserId uidInt) = do
    conn <- asks envConnection
    rows <- liftIO
      (query conn
        "SELECT p.match_id, p.pick FROM predictions p \
        \JOIN matches m ON m.id = p.match_id \
        \WHERE m.tournament_id = ? AND p.user_id = ? \
        \ORDER BY p.match_id"
        (tidInt, uidInt) :: IO [(Int64, String)])
    liftIO (mapM (\(mid, s) -> (\pk -> (MatchId mid, pk)) <$> decodePick s) rows)

  listTournamentPredictions :: TournamentId -> SQLiteM [(MatchId, UserId, Pick)]
  listTournamentPredictions (TournamentId tidInt) = do
    conn <- asks envConnection
    rows <- liftIO
      (query conn
        "SELECT p.match_id, p.user_id, p.pick FROM predictions p \
        \JOIN matches m ON m.id = p.match_id \
        \WHERE m.tournament_id = ? \
        \ORDER BY p.match_id, p.user_id"
        (Only tidInt) :: IO [(Int64, Int, String)])
    liftIO (mapM (\(mid, uid, s) -> (\pk -> (MatchId mid, UserId uid, pk)) <$> decodePick s) rows)
