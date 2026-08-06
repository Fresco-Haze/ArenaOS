module Main where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import Data.Int (Int64)
import System.Environment (getArgs)
import Text.Read (readMaybe)

import Shell.Persistence.SQLite.Connection (SQLiteM, SQLiteEnv(envConnection), runSQLiteM)
import Shell.Persistence.SQLite.Schema (initializeSchema)
import qualified Shell.Persistence.Port as Repo
import Shell.Persistence.Port (NewTournament(..))

-- Bringing SQLiteM's repository instances into scope (unused import list
-- is fine -- instances aren't named, so they come in regardless).
import Shell.Persistence.SQLite.ParticipantRepository ()
import Shell.Persistence.SQLite.UserRepository ()
import Shell.Persistence.SQLite.TournamentRepository ()
import Shell.Persistence.SQLite.RegistrationRepository ()
import Shell.Persistence.SQLite.BracketRepository ()
import Shell.Persistence.SQLite.MatchRepository ()

import Domain.Ids (TournamentId(..), BracketId(..),UserId(..))
import Domain.Participant (Participant(..), Player(..), PlayerName(..))
import Domain.Tournament
  ( TournamentName(..), OrganizerName(..), TournamentFormat(..)
  , Visibility(..)
  )
import Domain.User (User(..), Username(..), Email(..), AccountStatus(..))
import Domain.Match (Match(..), MatchId(..), MatchOutcome(..))

import Application.UseCases.CreateTournament (createTournament)
import Application.UseCases.RegisterParticipant (registerParticipant)
import Application.UseCases.GenerateBracket (generateBracket)
import Application.UseCases.StartMatch (startMatch)
import Application.UseCases.RecordMatchResult (recordMatchResult)
import Application.UseCases.CompleteTournament (completeTournament)

dbPath :: FilePath
dbPath = "arenaos-dev.db"

setupSchema :: SQLiteM ()
setupSchema = do
    env <- ask
    liftIO $ initializeSchema (envConnection env)

main :: IO ()
main = do
    args   <- getArgs
    result <- runSQLiteM dbPath (setupSchema >> dispatch args)
    case result of
        Left err -> putStrLn ("Database error: " ++ show err)
        Right () -> pure ()

-- | v0.1 CLI: one subcommand per use case, plus list-matches to find
-- match ids to act on. Individual players only for now (no Squad/team
-- support yet); format is fixed to SingleElimination and visibility to
-- Public -- matches what the test suite exercises, no flags for those
-- yet.
dispatch :: [String] -> SQLiteM ()
dispatch args = case args of

  ["create-tournament", uidStr, name, organizer, maxStr] ->
   case (readMaybe uidStr :: Maybe Int, readMaybe maxStr :: Maybe Int) of
    (Nothing, _) -> liftIO $ putStrLn "userId must be an integer"
    (_, Nothing) -> liftIO $ putStrLn "maxParticipants must be an integer"
    (Just uidInt, Just maxP) -> do
      tid <- createTournament NewTournament
        { newTournamentName            = TournamentName name
        , newTournamentOrganizer       = OrganizerName organizer
        , newTournamentOwner           = UserId uidInt
        , newTournamentFormat          = SingleElimination
        , newTournamentVisibility      = Public
        , newTournamentMaxParticipants = maxP
        }
      liftIO $ putStrLn ("Created tournament " ++ show (unTournamentId tid))

  ["register-user", username, email, password] -> do
    outcome <- registerUser RegisterUserRequest
      { registerUsername = Username (pack username)
      , registerEmail    = Email (pack email)
      , registerPassword = pack password
      }
    case outcome of
      Left err   -> liftIO $ putStrLn ("Registration failed: " ++ show err)
      Right user -> liftIO $ putStrLn ("Registered user " ++ show (unUserId (userId user)))

  ["register", tidStr, playerName] ->
    case readMaybe tidStr :: Maybe Int of
      Nothing -> liftIO $ putStrLn "tournamentId must be an integer"
      Just tidInt -> do
        let participant = Individual (Player (PlayerName playerName))
        Repo.savePlayer (Player (PlayerName playerName))
        _ <- registerParticipant (TournamentId tidInt) participant
        liftIO $ putStrLn (playerName ++ " registered into tournament " ++ show tidInt)

  ["generate-bracket", uidStr, tidStr] ->
    case (readMaybe uidStr :: Maybe Int, readMaybe tidStr :: Maybe Int) of
      (Nothing, _) -> liftIO $ putStrLn "userId must be an integer"
      (_, Nothing) -> liftIO $ putStrLn "tournamentId must be an integer"
      (Just uidInt, Just tidInt) -> do
        outcome <- generateBracket (UserId uidInt) (TournamentId tidInt)
        case outcome of
          Left err        -> liftIO $ putStrLn ("Bracket generation failed: " ++ show err)
          Right bracketId -> liftIO $ putStrLn ("Bracket generated: " ++ show (unBracketId bracketId))

  ["list-matches", bidStr] ->
    case readMaybe bidStr :: Maybe Int of
      Nothing -> liftIO $ putStrLn "bracketId must be an integer"
      Just bidInt -> do
        matches <- Repo.listMatchesForBracket (BracketId bidInt)
        liftIO $ mapM_ print matches

  ["start-match", midStr] ->
    case readMaybe midStr :: Maybe Int64 of
      Nothing -> liftIO $ putStrLn "matchId must be an integer"
      Just midInt -> do
        outcome <- startMatch (MatchId midInt)
        liftIO $ either (putStrLn . ("Start failed: " ++) . show) print outcome

  ["record-result", midStr, side] | side `elem` ["A", "B"] ->
    case readMaybe midStr :: Maybe Int64 of
      Nothing -> liftIO $ putStrLn "matchId must be an integer"
      Just midInt -> do
        match <- Repo.getMatch (MatchId midInt)
        let winner = if side == "A" then matchCompetitorA match else matchCompetitorB match
        outcome <- recordMatchResult (MatchId midInt) (Winner winner)
        liftIO $ either (putStrLn . ("Record result failed: " ++) . show) print outcome

  ["complete-tournament", tidStr] ->
    case readMaybe tidStr :: Maybe Int of
      Nothing -> liftIO $ putStrLn "tournamentId must be an integer"
      Just tidInt -> do
        outcome <- completeTournament (TournamentId tidInt)
        liftIO $ either (putStrLn . ("Complete failed: " ++) . show) print outcome

  _ -> liftIO $ putStrLn usage

usage :: String
usage = unlines
  [ "ArenaOS CLI"
  , "  create-tournament <name> <organizer> <maxParticipants>"
  , "  register <tournamentId> <playerName>"
  , "  generate-bracket <tournamentId>"
  , "  list-matches <bracketId>"
  , "  start-match <matchId>"
  , "  record-result <matchId> <A|B>"
  , "  complete-tournament <tournamentId>"
  ]