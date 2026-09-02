{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}

module Shell.Persistence.SQLite.EFootballScoreRepository () where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Database.SQLite.Simple (Only(..), execute, query)

import Domain.Match (MatchId(..))
import Domain.Scoreable (EFootballScore, mkEFootballScore, unEFootballScore)
import Shell.Persistence.Port (EFootballScoreRepository(..))
import Shell.Persistence.SQLite.Connection (SQLiteEnv(..), SQLiteM)
import Shell.Persistence.SQLite.Error (PersistenceError(..))
import Control.Exception (throwIO)

instance EFootballScoreRepository SQLiteM where

  saveEFootballScore :: MatchId -> EFootballScore -> EFootballScore -> SQLiteM ()
  saveEFootballScore (MatchId midInt) scoreA scoreB = do
    conn <- asks envConnection
    liftIO $ execute conn
      "INSERT INTO efootball_scores (match_id, competitor_a_score, competitor_b_score) \
      \VALUES (?, ?, ?) \
      \ON CONFLICT(match_id) DO UPDATE SET \
      \  competitor_a_score = excluded.competitor_a_score, \
      \  competitor_b_score = excluded.competitor_b_score"
      (midInt, unEFootballScore scoreA, unEFootballScore scoreB)

  getEFootballScore :: MatchId -> SQLiteM (Maybe (EFootballScore, EFootballScore))
  getEFootballScore (MatchId midInt) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn
        "SELECT competitor_a_score, competitor_b_score FROM efootball_scores WHERE match_id = ?"
        (Only midInt)
       :: IO [(Int, Int)])
    case rows of
      [(a, b)] -> do
        scoreA <- liftIO $ decodeScore a
        scoreB <- liftIO $ decodeScore b
        pure (Just (scoreA, scoreB))
      []  -> pure Nothing
      _   -> liftIO $ throwIO (StorageFailure ("Multiple efootball_scores rows for match " ++ show midInt))
   where
    decodeScore n = case mkEFootballScore n of
      Right s -> pure s
      Left _  -> throwIO (StorageFailure ("Corrupt (negative) eFootball score in storage for match " ++ show midInt))



      