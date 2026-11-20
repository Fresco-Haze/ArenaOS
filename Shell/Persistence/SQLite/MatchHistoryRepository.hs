{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}

module Shell.Persistence.SQLite.MatchHistoryRepository () where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Database.SQLite.Simple (Only(..), query)

import Domain.Match (MatchId(..))
import Domain.Participant (PlayerName(..))
import Shell.Persistence.Port (MatchHistoryRepository(..))
import Shell.Persistence.SQLite.Connection (SQLiteEnv(..), SQLiteM)

instance MatchHistoryRepository SQLiteM where

  listMatchIdsForPlayer :: PlayerName -> Int -> SQLiteM [MatchId]
  listMatchIdsForPlayer (PlayerName n) limitN = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn
        "SELECT m.id FROM matches m \
        \WHERE m.status = 'Completed' AND ( \
        \  m.competitor_a_participant_id IN (SELECT pa.id FROM participants pa JOIN players p ON p.id = pa.player_id WHERE p.name = ? COLLATE NOCASE) \
        \  OR m.competitor_b_participant_id IN (SELECT pa.id FROM participants pa JOIN players p ON p.id = pa.player_id WHERE p.name = ? COLLATE NOCASE) \
        \  OR m.competitor_a_participant_id IN (SELECT pa.id FROM participants pa JOIN team_members tm ON tm.team_id = pa.team_id JOIN players p ON p.id = tm.player_id WHERE p.name = ? COLLATE NOCASE) \
        \  OR m.competitor_b_participant_id IN (SELECT pa.id FROM participants pa JOIN team_members tm ON tm.team_id = pa.team_id JOIN players p ON p.id = tm.player_id WHERE p.name = ? COLLATE NOCASE) \
        \) ORDER BY m.id DESC LIMIT ?"
        (n, n, n, n, limitN)
       :: IO [Only Int])
    pure [ MatchId (fromIntegral i) | Only i <- rows ]