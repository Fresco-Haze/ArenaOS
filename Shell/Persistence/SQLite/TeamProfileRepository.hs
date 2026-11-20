{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}

module Shell.Persistence.SQLite.TeamProfileRepository () where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Database.SQLite.Simple (Only(..), execute, query)

import Domain.Participant (TeamName(..))
import Domain.TeamProfile (Recruitment(..), TeamProfile(..))
import Shell.Persistence.Port (TeamProfileRepository(..))
import Shell.Persistence.SQLite.Connection (SQLiteEnv(..), SQLiteM)

recruitmentToText :: Recruitment -> String
recruitmentToText OpenTryouts = "OpenTryouts"
recruitmentToText InviteOnly  = "InviteOnly"

textToRecruitment :: String -> Recruitment
textToRecruitment "OpenTryouts" = OpenTryouts
textToRecruitment _             = InviteOnly

instance TeamProfileRepository SQLiteM where

  setTeamProfile :: TeamName -> TeamProfile -> SQLiteM ()
  setTeamProfile (TeamName tname) (TeamProfile tag game region rec) = do
    conn <- asks envConnection
    liftIO $ execute conn
      "INSERT INTO team_profiles (team_id, tag, game, region, recruitment) \
      \SELECT id, ?, ?, ?, ? FROM teams WHERE name = ? COLLATE NOCASE \
      \ON CONFLICT(team_id) DO UPDATE SET tag = excluded.tag, game = excluded.game, \
      \region = excluded.region, recruitment = excluded.recruitment"
      (tag, game, region, recruitmentToText rec, tname)

  getTeamProfile :: TeamName -> SQLiteM (Maybe TeamProfile)
  getTeamProfile (TeamName tname) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn
        "SELECT p.tag, p.game, p.region, p.recruitment FROM team_profiles p \
        \JOIN teams t ON t.id = p.team_id WHERE t.name = ? COLLATE NOCASE"
        (Only tname)
       :: IO [(String, String, String, String)])
    pure (case rows of
            ((tag, game, region, rec) : _) -> Just (TeamProfile tag game region (textToRecruitment rec))
            []                             -> Nothing)

  getTeamRecord :: TeamName -> SQLiteM (Int, Int)
  getTeamRecord (TeamName tname) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn
        "SELECT \
        \  COALESCE(SUM(CASE WHEN m.outcome_participant_id = p.id THEN 1 ELSE 0 END), 0), \
        \  COALESCE(SUM(CASE WHEN m.outcome_participant_id IS NOT NULL AND m.outcome_participant_id <> p.id THEN 1 ELSE 0 END), 0) \
        \FROM matches m \
        \JOIN participants p ON p.id IN (m.competitor_a_participant_id, m.competitor_b_participant_id) \
        \JOIN teams t ON t.id = p.team_id \
        \WHERE m.status = 'Completed' AND t.name = ? COLLATE NOCASE"
        (Only tname)
       :: IO [(Int, Int)])
    pure (case rows of
            (r : _) -> r
            []      -> (0, 0))