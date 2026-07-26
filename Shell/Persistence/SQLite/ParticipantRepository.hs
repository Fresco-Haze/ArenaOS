{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs #-}
module Shell.Persistence.SQLite.ParticipantRepository () where

import Control.Exception (throwIO)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Database.SQLite.Simple (Connection, changes, execute, query,lastInsertRowId, Only(..))
import Data.List (nub)

import Domain.Participant (Player(..), PlayerName(..), Team(..), TeamName(..), Participant(..), ParticipantId(..))
import Shell.Persistence.Port (ParticipantRepository(..))
import Shell.Persistence.SQLite.Connection (SQLiteEnv(envConnection), SQLiteM, withTxM)
import Shell.Persistence.SQLite.Error (PersistenceError(..))

instance ParticipantRepository SQLiteM where
    savePlayer :: Player -> SQLiteM ()
    savePlayer (Player (PlayerName pname)) = do
        conn <- asks envConnection
        liftIO $ execute conn
          "INSERT INTO players (name) VALUES (?) \
          \ON CONFLICT(name) DO UPDATE SET name = excluded.name"
          (Only pname)

    getTeam :: TeamName -> SQLiteM Team
    getTeam (TeamName tname) = do
        conn <- asks envConnection
        rows <- liftIO (query conn
          "SELECT id, captain_player_id FROM teams WHERE name = ?"
          (Only tname) :: IO [(Int, Int)])
        case rows of
            [(tid, captainId)] -> do
                captain <- liftIO $ getPlayerById conn captainId
                memberIds <- liftIO (query conn
                  "SELECT player_id FROM team_members WHERE team_id = ?"
                  (Only tid) :: IO [Only Int])
                members <- liftIO $ traverse
                  (\(Only pid) -> getPlayerById conn pid)
                  memberIds
                pure (Team (TeamName tname) captain members)
            [] ->
                liftIO $ throwIO (NotFound ("Team not found: " ++ tname))
            _ ->
                liftIO $ throwIO
                  (StorageFailure
                    "teams.name is UNIQUE but multiple rows were returned")

    getPlayer :: PlayerName -> SQLiteM Player
    getPlayer (PlayerName pname) = do
        conn <- asks envConnection
        let sql = "SELECT name FROM players WHERE name = ?"
        rows <- liftIO (query conn sql (Only pname) :: IO [Only String])
        case rows of
            [Only n] ->
                pure (Player (PlayerName n))
            [] ->
                liftIO $
                    throwIO (NotFound ("Player not found: " ++ pname))
            _ ->
                liftIO $
                    throwIO
                      (StorageFailure
                        "players.name is UNIQUE but multiple rows were returned")

    deletePlayer :: PlayerName -> SQLiteM ()
    deletePlayer (PlayerName pname) = do
        conn <- asks envConnection
        liftIO $ execute conn
          "DELETE FROM players WHERE name = ?"
          (Only pname)
        n <- liftIO $ changes conn
        if n == 0
            then liftIO $
                throwIO (NotFound ("Player not found: " ++ pname))
            else pure ()

    saveTeam :: Team -> SQLiteM ()
    saveTeam team = withTxM $ do
        conn <- asks envConnection

        -- 1. Upsert the teams row (captain resolved to its player id first,
        --    since captain_player_id is NOT NULL — no valid team row without it)
        captainId <- getPlayerIdByName (playerName (teamCaptain team))
        let TeamName tname = teamName team
        liftIO $ execute conn
          "INSERT INTO teams (name, captain_player_id) VALUES (?, ?) \
          \ON CONFLICT(name) DO UPDATE SET captain_player_id = excluded.captain_player_id"
          (tname, captainId)

        -- 2. Resolve the team's id (upsert doesn't return it directly)
        teamId <- getTeamIdByName (teamName team)

        -- 3. Clear existing membership — RC-01 transitive clause: no stale
        --    associations may survive a save
        liftIO $ execute conn
          "DELETE FROM team_members WHERE team_id = ?" (Only teamId)

        -- 4/5. Insert one row per current member
        memberIds <- mapM (getPlayerIdByName . playerName) (teamMembers team)

        liftIO $ mapM_
          (\pid -> execute conn
            "INSERT INTO team_members (team_id, player_id) VALUES (?, ?)"
            (teamId, pid))
          memberIds

    deleteTeam :: TeamName -> SQLiteM ()
    deleteTeam (TeamName tname) = withTxM $ do
        conn <- asks envConnection

        teamId <- getTeamIdByName (TeamName tname)

        liftIO $ execute conn
          "DELETE FROM team_members WHERE team_id = ?"
          (Only teamId)

        liftIO $ execute conn
          "DELETE FROM teams WHERE id = ?"
          (Only teamId)

    resolveParticipant :: Participant -> SQLiteM ParticipantId
    resolveParticipant participant = do
        conn <- asks envConnection
        case participant of
            Individual player -> do
                pid <- getPlayerIdByName (playerName player)
                liftIO $ findOrInsertParticipant conn "Individual" (Just pid) Nothing
            Squad team -> do
                tid <- getTeamIdByName (teamName team)
                liftIO $ findOrInsertParticipant conn "Squad" Nothing (Just tid)

    getParticipant :: ParticipantId -> SQLiteM Participant
    getParticipant (ParticipantId pid) = do
        conn <- asks envConnection
        rows <- liftIO (query conn
          "SELECT kind, player_id, team_id FROM participants WHERE id = ?"
          (Only pid) :: IO [(String, Maybe Int, Maybe Int)])
        case rows of
            [("Individual", Just playerId, Nothing)] -> do
                player <- liftIO $ getPlayerById conn playerId
                pure (Individual player)
            [("Squad", Nothing, Just teamId)] -> do
                team <- liftIO $ getTeamById conn teamId
                pure (Squad team)
            [] ->
                liftIO $ throwIO (NotFound ("Participant not found with id: " ++ show pid))
            _ ->
                liftIO $ throwIO
                  (StorageFailure
                    ("participants row for id " ++ show pid ++ " violates kind/player_id/team_id invariant"))


-- Private helpers, not part of the port. The port speaks only in
-- domain types (PlayerName, TeamName); these bridge to the surrogate
-- ids the schema uses internally. Candidates for reuse in getTeam,
-- resolveParticipant, and RegistrationRepository once those exist --
-- kept local here until that repetition actually shows up.

getPlayerIdByName :: PlayerName -> SQLiteM Int
getPlayerIdByName (PlayerName pname) = do
    conn <- asks envConnection
    rows <- liftIO $ query conn
      "SELECT id FROM players WHERE name = ?" (Only pname)
    case rows of
        (Only pid : _) -> pure pid
        []             -> liftIO $ throwIO (NotFound ("player: " <> pname))

getPlayerById :: Connection -> Int -> IO Player
getPlayerById conn pid = do
    rows <- query conn
      "SELECT name FROM players WHERE id = ?"
      (Only pid) :: IO [Only String]
    case rows of
        [Only n] -> pure (Player (PlayerName n))
        [] -> throwIO (NotFound ("Player not found with id: " ++ show pid))
        _  -> throwIO
                (StorageFailure
                  "players.id is PRIMARY KEY but multiple rows were returned")

getTeamById :: Connection -> Int -> IO Team
getTeamById conn tid = do
    rows <- query conn
      "SELECT name, captain_player_id FROM teams WHERE id = ?"
      (Only tid) :: IO [(String, Int)]
    case rows of
        [(tname, captainId)] -> do
            captain <- getPlayerById conn captainId
            memberIds <- query conn
              "SELECT player_id FROM team_members WHERE team_id = ?"
              (Only tid) :: IO [Only Int]
            members <- traverse (\(Only pid) -> getPlayerById conn pid) memberIds
            pure (Team (TeamName tname) captain members)
        [] -> throwIO (NotFound ("Team not found with id: " ++ show tid))
        _  -> throwIO
                (StorageFailure
                  "teams.id is PRIMARY KEY but multiple rows were returned")

getTeamIdByName :: TeamName -> SQLiteM Int
getTeamIdByName (TeamName tname) = do
    conn <- asks envConnection
    rows <- liftIO $ query conn
      "SELECT id FROM teams WHERE name = ?" (Only tname)
    case rows of
        (Only tid : _) -> pure tid
        []             -> liftIO $ throwIO (NotFound ("team: " <> tname))

findOrInsertParticipant :: Connection -> String -> Maybe Int -> Maybe Int -> IO ParticipantId
findOrInsertParticipant conn kind mPlayerId mTeamId = do
    existing <- query conn
      "SELECT id FROM participants WHERE kind = ? AND player_id IS ? AND team_id IS ?"
      (kind, mPlayerId, mTeamId) :: IO [Only Int]
    case existing of
        [Only pid] -> pure (ParticipantId pid)
        [] -> do
            execute conn
              "INSERT INTO participants (kind, player_id, team_id) VALUES (?, ?, ?)"
              (kind, mPlayerId, mTeamId)
            newId <- lastInsertRowId conn
            pure (ParticipantId (fromIntegral newId))
        _ -> throwIO
               (StorageFailure
                 "participants row uniqueness violated for this kind/player_id/team_id")