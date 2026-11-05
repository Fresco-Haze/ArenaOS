{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE InstanceSigs #-}

-- Shell.Persistence.SQLite.LobbyRepository
-- Storage for lobby tournaments: kind, scoring settings, rounds and results.

module Shell.Persistence.SQLite.LobbyRepository () where

import Control.Exception (throwIO)
import Control.Monad (forM, when)
import Control.Monad.Reader (asks, liftIO)
import Data.List (intercalate)
import Database.SQLite.Simple (Only(..), changes, execute, query)
import Text.Read (readMaybe)

import Domain.Lobby (GameEntry(..), LobbySettings(..), defaultLobbySettings)
import Domain.Participant (ParticipantId(..))
import Domain.Tournament (TournamentId(..), TournamentKind(..))
import Shell.Persistence.Port (LobbyRepository(..))
import Shell.Persistence.SQLite.Connection (SQLiteM, envConnection)
import Shell.Persistence.SQLite.Error (PersistenceError(..))

kindToText :: TournamentKind -> String
kindToText BracketKind = "Bracket"
kindToText LobbyKind   = "Lobby"

-- Placement points are stored as a comma list, like "10,6,5".
encodePoints :: [Int] -> String
encodePoints = intercalate "," . map show

decodePoints :: String -> Maybe [Int]
decodePoints = traverse readMaybe . splitCommas

splitCommas :: String -> [String]
splitCommas s = case break (== ',') s of
  (a, [])       -> [a]
  (a, _ : rest) -> a : splitCommas rest

instance LobbyRepository SQLiteM where
  setTournamentKind :: TournamentId -> TournamentKind -> SQLiteM ()
  setTournamentKind (TournamentId tid) kind = do
    conn <- asks envConnection
    liftIO $ execute conn
      "UPDATE tournaments SET kind = ? WHERE id = ?"
      (kindToText kind, tid)
    n <- liftIO $ changes conn
    when (n == 0) $
      liftIO $ throwIO (NotFound ("Tournament not found: " ++ show tid))

  getLobbySettings :: TournamentId -> SQLiteM LobbySettings
  getLobbySettings (TournamentId tid) = do
    conn <- asks envConnection
    rows <- liftIO (query conn
      "SELECT kill_points, placement_points FROM lobby_settings WHERE tournament_id = ?"
      (Only tid)
      :: IO [(Int, String)])
    case rows of
      [] -> pure defaultLobbySettings
      ((kp, txt) : _) -> case decodePoints txt of
        Just ps | not (null ps) -> pure (LobbySettings kp ps)
        _ -> liftIO (throwIO (StorageFailure ("Bad placement points in storage: " ++ txt)))

  saveLobbySettings :: TournamentId -> LobbySettings -> SQLiteM ()
  saveLobbySettings (TournamentId tid) (LobbySettings kp ps) = do
    when (null ps) $
      liftIO (throwIO (StorageFailure "Placement points must not be empty"))
    conn <- asks envConnection
    liftIO $ execute conn
      "INSERT INTO lobby_settings (tournament_id, kill_points, placement_points) VALUES (?, ?, ?) \
      \ON CONFLICT(tournament_id) DO UPDATE SET kill_points = excluded.kill_points, placement_points = excluded.placement_points"
      (tid, kp, encodePoints ps)

  addLobbyRound :: TournamentId -> SQLiteM Int
  addLobbyRound (TournamentId tid) = do
    conn <- asks envConnection
    rows <- liftIO (query conn
      "SELECT COALESCE(MAX(game_number), 0) + 1 FROM lobby_games WHERE tournament_id = ?"
      (Only tid)
      :: IO [Only Int])
    case rows of
      [Only n] -> do
        liftIO $ execute conn
          "INSERT INTO lobby_games (tournament_id, game_number) VALUES (?, ?)"
          (tid, n)
        pure n
      _ -> liftIO (throwIO (StorageFailure "Unexpected lobby round number result"))

  saveLobbyRoundResults :: TournamentId -> Int -> [GameEntry ParticipantId] -> SQLiteM ()
  saveLobbyRoundResults (TournamentId tid) roundNo entries = do
    conn <- asks envConnection
    rows <- liftIO (query conn
      "SELECT id FROM lobby_games WHERE tournament_id = ? AND game_number = ?"
      (tid, roundNo)
      :: IO [Only Int])
    case rows of
      [] -> liftIO (throwIO (NotFound
              ("Lobby round not found: tournament " ++ show tid ++ ", round " ++ show roundNo)))
      (Only gid : _) -> liftIO $ do
        execute conn "DELETE FROM lobby_results WHERE lobby_game_id = ?" (Only gid)
        mapM_ (\e -> execute conn
                 "INSERT INTO lobby_results (lobby_game_id, participant_id, placement, kills) VALUES (?, ?, ?, ?)"
                 (gid, unParticipantId (entryParticipant e), entryPlacement e, entryKills e))
              entries

  listLobbyRounds :: TournamentId -> SQLiteM [(Int, [GameEntry ParticipantId])]
  listLobbyRounds (TournamentId tid) = do
    conn <- asks envConnection
    liftIO $ do
      rounds <- query conn
        "SELECT id, game_number FROM lobby_games WHERE tournament_id = ? ORDER BY game_number"
        (Only tid) :: IO [(Int, Int)]
      forM rounds $ \(gid, n) -> do
        rs <- query conn
          "SELECT participant_id, placement, kills FROM lobby_results WHERE lobby_game_id = ? ORDER BY placement"
          (Only gid) :: IO [(Int, Int, Int)]
        pure (n, [ GameEntry (ParticipantId p) pl k | (p, pl, k) <- rs ])