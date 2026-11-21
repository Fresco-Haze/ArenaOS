{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}

module Shell.Persistence.SQLite.SeriesRepository () where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Database.SQLite.Simple (Only(..), execute, query)

import Domain.Ids (UserId(..), TournamentId(..))
import Domain.Match (MatchId(..))
import Domain.Series (MatchGame(..))
import Shell.Persistence.Port (SeriesRepository(..))
import Shell.Persistence.SQLite.Connection (SQLiteEnv(..), SQLiteM)

instance SeriesRepository SQLiteM where

  setBestOf :: TournamentId -> Int -> SQLiteM ()
  setBestOf (TournamentId tid) n = do
    conn <- asks envConnection
    liftIO $ execute conn
      "INSERT INTO tournament_series (tournament_id, best_of) VALUES (?, ?) \
      \ON CONFLICT(tournament_id) DO UPDATE SET best_of = excluded.best_of"
      (tid, n)

  getBestOf :: TournamentId -> SQLiteM Int
  getBestOf (TournamentId tid) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn "SELECT best_of FROM tournament_series WHERE tournament_id = ?" (Only tid)
       :: IO [Only Int])
    pure (case rows of
            (Only n : _) -> n
            []           -> 1)

  countSeriesGames :: TournamentId -> SQLiteM Int
  countSeriesGames (TournamentId tid) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn
        "SELECT COUNT(*) FROM match_games g JOIN matches m ON m.id = g.match_id WHERE m.tournament_id = ?"
        (Only tid)
       :: IO [Only Int])
    pure (case rows of
            (Only n : _) -> n
            []           -> 0)

  listMatchGames :: MatchId -> SQLiteM [MatchGame]
  listMatchGames (MatchId mid) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn
        "SELECT game_no, score_a, score_b, confirmed, reported_by FROM match_games \
        \WHERE match_id = ? ORDER BY game_no"
        (Only mid)
       :: IO [(Int, Int, Int, Int, Int)])
    pure [ MatchGame n a b (c /= 0) (UserId u) | (n, a, b, c, u) <- rows ]

  upsertMatchGame :: MatchId -> Int -> Int -> Int -> Bool -> UserId -> SQLiteM ()
  upsertMatchGame (MatchId mid) gno a b confirmed (UserId by) = do
    conn <- asks envConnection
    let c = if confirmed then 1 else 0 :: Int
    liftIO $ execute conn
      "INSERT INTO match_games (match_id, game_no, score_a, score_b, confirmed, reported_by) \
      \VALUES (?, ?, ?, ?, ?, ?) \
      \ON CONFLICT(match_id, game_no) DO UPDATE SET score_a = excluded.score_a, \
      \score_b = excluded.score_b, confirmed = excluded.confirmed, reported_by = excluded.reported_by"
      (mid, gno, a, b, c, by)