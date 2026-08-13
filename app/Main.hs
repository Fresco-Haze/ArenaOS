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
import Shell.Infrastructure.PasswordHasher ()
import Shell.Persistence.SQLite.TournamentHistoryRepository ()

import Domain.Ids (TournamentId(..), BracketId(..),UserId(..))
import Domain.Participant (Participant(..), Player(..), PlayerName(..), Team(..), TeamName(..), TeamCaptain(..))
import Domain.Tournament
  ( TournamentName(..), OrganizerName(..), TournamentFormat(..)
  , Visibility(..), TournamentState(..)
  )
import Domain.User (User(..), Username(..), Email(..), AccountStatus(..))
import Domain.Match (Match(..), MatchId(..), MatchOutcome(..))

import Application.UseCases.CreateTournament (createTournament)
import Application.UseCases.RegisterParticipant (registerParticipant, RegisterParticipantError(..))
import Application.UseCases.GenerateBracket (generateBracket)
import Application.UseCases.StartMatch (startMatch)
import Application.UseCases.RecordMatchResult (recordMatchResult)
import Application.UseCases.CompleteTournament (completeTournament)
import Data.Text (pack)
import Domain.User (User(..), Username(..))
import Application.UseCases.LoginUser (LoginUserRequest(..), loginUser)
import Application.UseCases.LogoutUser (logoutUser)
import Shell.Auth.Session (saveSession)
import Application.UseCases.RegisterUser (RegisterUserRequest(..), registerUser)
import Application.UseCases.ChangePassword (ChangePasswordRequest(..), changePassword)
import Application.UseCases.UpdateProfile (UpdateProfileRequest(..), updateProfile)
import Application.UseCases.SetAccountStatus (SetAccountStatusRequest(..), setAccountStatus)
import Application.UseCases.PublishTournament (publishTournament)
import Application.UseCases.OpenRegistration (openRegistration)
import Application.UseCases.CloseRegistration (closeRegistration)
import Application.UseCases.StartTournament (startTournament)
import Application.UseCases.CancelTournament (cancelTournament)
import Application.UseCases.UpdateTournamentName (updateTournamentName)
import Application.UseCases.UpdateTournamentVisibility (updateTournamentVisibility)
import Application.UseCases.UpdateTournamentFormat (updateTournamentFormat)
import Application.UseCases.CreateTeam (createTeam)
import Application.UseCases.UpdateTournamentMaxParticipants (updateTournamentMaxParticipants)
import Application.UseCases.GetOrganizerDashboard (getOrganizerDashboard, GetOrganizerDashboardError(..), OrganizerDashboard(..), StateCounts(..))
import Application.UseCases.RegisterCodParticipant (registerCodParticipant, RegisterCodParticipantError(..))
import Application.UseCases.RegisterPubgParticipant
  ( registerPubgParticipant
  , RegisterPubgParticipantError(..)
  )
import Application.UseCases.GetOrganizerDashboard
    (getOrganizerDashboard, GetOrganizerDashboardError(..), OrganizerDashboard(..), StateCounts(..))
import Application.UseCases.GetTournamentHistory
    (getTournamentHistory, GetTournamentHistoryError(..))
import Domain.TournamentHistory
    (TournamentHistoryEntry(..), TournamentHistoryEvent(..), ChangedField(..))

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
        outcome <- registerParticipant (TournamentId tidInt) participant
        liftIO $ case outcome of
          Left err -> putStrLn ("Registration failed: " ++ show err)
          Right _  -> putStrLn (playerName ++ " registered into tournament " ++ show tidInt)

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

  ["start-match",uidStr, midStr] ->
    case (readMaybe uidStr :: Maybe Int,  readMaybe midStr :: Maybe Int64) of
      (Nothing, _) -> liftIO $ putStrLn "userId must be an integer" 
      (_,Nothing) -> liftIO $ putStrLn "matchId must be an integer"
      (Just uidInt,   Just midInt) -> do
        outcome <- startMatch (UserId uidInt) (MatchId midInt)
        liftIO $ either (putStrLn . ("Start failed: " ++) . show) print outcome

  ["record-result", uidStr, midStr, side] | side `elem` ["A", "B"] ->
   case (readMaybe uidStr :: Maybe Int, readMaybe midStr :: Maybe Int64) of
    (Nothing, _) -> liftIO $ putStrLn "userId must be an integer"
    (_, Nothing) -> liftIO $ putStrLn "matchId must be an integer"
    (Just uidInt, Just midInt) -> do
      match <- Repo.getMatch (MatchId midInt)
      let winner = if side == "A" then matchCompetitorA match else matchCompetitorB match
      outcome <- recordMatchResult (UserId uidInt) (MatchId midInt) (Winner winner)
      liftIO $ either (putStrLn . ("Record result failed: " ++) . show) print outcome
  ["complete-tournament",uidStr, tidStr] ->
    case (readMaybe uidStr :: Maybe Int,  readMaybe tidStr :: Maybe Int) of
      (Nothing, _) -> liftIO $ putStrLn "userId must be an integer"
      (_,Nothing) -> liftIO $ putStrLn "tournamentId must be an integer"
      (Just uidInt,   Just tidInt) -> do
        outcome <- completeTournament (UserId uidInt) (TournamentId tidInt)
        liftIO $ either (putStrLn . ("Complete failed: " ++) . show) print outcome

  ["login", username, password] -> do
    outcome <- loginUser LoginUserRequest
      { loginUsername = Username (pack username)
      , loginPassword = pack password
      }
    case outcome of
      Left err   -> liftIO $ putStrLn ("Login failed: " ++ show err)
      Right user -> liftIO $ do
        saveSession (userId user)
        putStrLn "Logged in."

  ["logout"] -> liftIO $ do
    logoutUser
    putStrLn "Logged out."



  ["my-tournaments", uidStr] ->
    case readMaybe uidStr :: Maybe Int of
      Nothing -> liftIO $ putStrLn "userId must be an integer"
      Just uidInt -> do
        tournaments <- Repo.listTournamentsByOwner (UserId uidInt)
        liftIO $ case tournaments of
          [] -> putStrLn "You don't own any tournaments."
          _  -> mapM_ print tournaments

  ["change-password", uidStr, currentPassword, newPassword] ->
    case readMaybe uidStr :: Maybe Int of
    Nothing -> liftIO $ putStrLn "userId must be an integer"
    Just uidInt -> do
      outcome <- changePassword ChangePasswordRequest
        { changePasswordUserId  = UserId uidInt
        , changePasswordCurrent = pack currentPassword
        , changePasswordNew     = pack newPassword
        }
      case outcome of
        Left err -> liftIO $ putStrLn ("Change password failed: " ++ show err)
        Right () -> liftIO $ putStrLn "Password changed."

  ["profile", uidStr] ->
    case readMaybe uidStr :: Maybe Int of
      Nothing -> liftIO $ putStrLn "userId must be an integer"
      Just uidInt -> do
        maybeUser <- Repo.findUserById (UserId uidInt)
        liftIO $ case maybeUser of
          Nothing   -> putStrLn "No user found with that id."
          Just user -> print user

  ["update-profile", uidStr, usernameArg, emailArg] ->
    case readMaybe uidStr :: Maybe Int of
      Nothing -> liftIO $ putStrLn "userId must be an integer"
      Just uidInt -> do
        let newUsername = if usernameArg == "-" then Nothing else Just (Username (pack usernameArg))
            newEmail    = if emailArg    == "-" then Nothing else Just (Email (pack emailArg))
        outcome <- updateProfile UpdateProfileRequest
          { updateProfileUserId      = UserId uidInt
          , updateProfileNewUsername = newUsername
          , updateProfileNewEmail    = newEmail
          }
        case outcome of
          Left err -> liftIO $ putStrLn ("Update profile failed: " ++ show err)
          Right () -> liftIO $ putStrLn "Profile updated."

  ["set-account-status", uidStr, statusStr] ->
    case (readMaybe uidStr :: Maybe Int, parseStatus statusStr) of
      (Nothing, _) -> liftIO $ putStrLn "userId must be an integer"
      (_, Nothing) -> liftIO $ putStrLn "status must be one of: Active, Suspended, Deactivated"
      (Just uidInt, Just status) -> do
        outcome <- setAccountStatus SetAccountStatusRequest
          { statusUserId = UserId uidInt
          , statusNew    = status
          }
        case outcome of
          Left err -> liftIO $ putStrLn ("Set status failed: " ++ show err)
          Right () -> liftIO $ putStrLn "Account status updated."
  ["publish-tournament", uidStr, tidStr] ->
    case (readMaybe uidStr :: Maybe Int, readMaybe tidStr :: Maybe Int) of
      (Nothing, _) -> liftIO $ putStrLn "userId must be an integer"
      (_, Nothing) -> liftIO $ putStrLn "tournamentId must be an integer"
      (Just uidInt, Just tidInt) -> do
        outcome <- publishTournament (UserId uidInt) (TournamentId tidInt)
        liftIO $ either (putStrLn . ("Publish failed: " ++) . show) (const (putStrLn "Tournament published.")) outcome

  ["open-registration", uidStr, tidStr] ->
    case (readMaybe uidStr :: Maybe Int, readMaybe tidStr :: Maybe Int) of
      (Nothing, _) -> liftIO $ putStrLn "userId must be an integer"
      (_, Nothing) -> liftIO $ putStrLn "tournamentId must be an integer"
      (Just uidInt, Just tidInt) -> do
        outcome <- openRegistration (UserId uidInt) (TournamentId tidInt)
        liftIO $ either (putStrLn . ("Open registration failed: " ++) . show) (const (putStrLn "Registration opened.")) outcome

  ["close-registration", uidStr, tidStr] ->
    case (readMaybe uidStr :: Maybe Int, readMaybe tidStr :: Maybe Int) of
      (Nothing, _) -> liftIO $ putStrLn "userId must be an integer"
      (_, Nothing) -> liftIO $ putStrLn "tournamentId must be an integer"
      (Just uidInt, Just tidInt) -> do
        outcome <- closeRegistration (UserId uidInt) (TournamentId tidInt)
        liftIO $ either (putStrLn . ("Close registration failed: " ++) . show) (const (putStrLn "Registration closed.")) outcome

  ["start-tournament", uidStr, tidStr] ->
    case (readMaybe uidStr :: Maybe Int, readMaybe tidStr :: Maybe Int) of
      (Nothing, _) -> liftIO $ putStrLn "userId must be an integer"
      (_, Nothing) -> liftIO $ putStrLn "tournamentId must be an integer"
      (Just uidInt, Just tidInt) -> do
        outcome <- startTournament (UserId uidInt) (TournamentId tidInt)
        liftIO $ either (putStrLn . ("Start failed: " ++) . show) (const (putStrLn "Tournament started.")) outcome

  ["cancel-tournament", uidStr, tidStr, reason] ->
    case (readMaybe uidStr :: Maybe Int, readMaybe tidStr :: Maybe Int) of
      (Nothing, _) -> liftIO $ putStrLn "userId must be an integer"
      (_, Nothing) -> liftIO $ putStrLn "tournamentId must be an integer"
      (Just uidInt, Just tidInt) -> do
        outcome <- cancelTournament (UserId uidInt) (TournamentId tidInt) reason
        liftIO $ either (putStrLn . ("Cancel failed: " ++) . show) (const (putStrLn "Tournament cancelled.")) outcome

  ["update-tournament-name", uidStr, tidStr, name] ->
    case (readMaybe uidStr :: Maybe Int, readMaybe tidStr :: Maybe Int) of
      (Nothing, _) -> liftIO $ putStrLn "userId must be an integer"
      (_, Nothing) -> liftIO $ putStrLn "tournamentId must be an integer"
      (Just uidInt, Just tidInt) -> do
        outcome <- updateTournamentName (UserId uidInt) (TournamentId tidInt) (TournamentName name)
        liftIO $ either (putStrLn . ("Update failed: " ++) . show) (const (putStrLn "Name updated.")) outcome

  ["update-tournament-visibility", uidStr, tidStr, visStr] ->
    case (readMaybe uidStr :: Maybe Int, readMaybe tidStr :: Maybe Int, parseVisibility visStr) of
      (Nothing, _, _) -> liftIO $ putStrLn "userId must be an integer"
      (_, Nothing, _) -> liftIO $ putStrLn "tournamentId must be an integer"
      (_, _, Nothing) -> liftIO $ putStrLn "visibility must be one of: Public, Private"
      (Just uidInt, Just tidInt, Just vis) -> do
        outcome <- updateTournamentVisibility (UserId uidInt) (TournamentId tidInt) vis
        liftIO $ either (putStrLn . ("Update failed: " ++) . show) (const (putStrLn "Visibility updated.")) outcome

  ["update-tournament-format", uidStr, tidStr, fmtStr] ->
    case (readMaybe uidStr :: Maybe Int, readMaybe tidStr :: Maybe Int, parseFormat fmtStr) of
      (Nothing, _, _) -> liftIO $ putStrLn "userId must be an integer"
      (_, Nothing, _) -> liftIO $ putStrLn "tournamentId must be an integer"
      (_, _, Nothing) -> liftIO $ putStrLn "format must be one of: SingleElimination, DoubleElimination, RoundRobin"
      (Just uidInt, Just tidInt, Just fmt) -> do
        outcome <- updateTournamentFormat (UserId uidInt) (TournamentId tidInt) fmt
        liftIO $ either (putStrLn . ("Update failed: " ++) . show) (const (putStrLn "Format updated.")) outcome

  ["update-tournament-max-participants", uidStr, tidStr, maxStr] ->
    case (readMaybe uidStr :: Maybe Int, readMaybe tidStr :: Maybe Int, readMaybe maxStr :: Maybe Int) of
      (Nothing, _, _) -> liftIO $ putStrLn "userId must be an integer"
      (_, Nothing, _) -> liftIO $ putStrLn "tournamentId must be an integer"
      (_, _, Nothing) -> liftIO $ putStrLn "maxParticipants must be an integer"
      (Just uidInt, Just tidInt, Just newMax) -> do
        outcome <- updateTournamentMaxParticipants (UserId uidInt) (TournamentId tidInt) newMax
        liftIO $ either (putStrLn . ("Update failed: " ++) . show) (const (putStrLn "Max participants updated.")) outcome

  ["dashboard"] -> do
    outcome <- getOrganizerDashboard
    liftIO $ case outcome of
      Left err   -> putStrLn ("Dashboard failed: " ++ show err)
      Right dash -> do
        putStrLn "=== Organizer Dashboard ==="
        let c = dashboardCounts dash
        putStrLn ("Draft: " ++ show (countDraft c))
        putStrLn ("Published: " ++ show (countPublished c))
        putStrLn ("RegistrationOpen: " ++ show (countRegistrationOpen c))
        putStrLn ("RegistrationClosed: " ++ show (countRegistrationClosed c))
        putStrLn ("InProgress: " ++ show (countInProgress c))
        putStrLn ("Completed: " ++ show (countCompleted c))
        putStrLn ("Cancelled: " ++ show (countCancelled c))
        putStrLn "--- Tournaments ---"
        mapM_ print (dashboardTournaments dash)


  ["history", uidStr, tidStr] ->
    case (readMaybe uidStr :: Maybe Int, readMaybe tidStr :: Maybe Int) of
      (Nothing, _) -> liftIO $ putStrLn "userId must be an integer"
      (_, Nothing) -> liftIO $ putStrLn "tournamentId must be an integer"
      (Just uidInt, Just tidInt) -> do
        outcome <- getTournamentHistory (UserId uidInt) (TournamentId tidInt)
        liftIO $ case outcome of
          Left err      -> putStrLn ("History failed: " ++ show err)
          Right entries -> do
            putStrLn ("=== Tournament " ++ show tidInt ++ " History ===")
            if null entries
              then putStrLn "(no history entries)"
              else mapM_ printEntry entries
    where
      printEntry entry =
        putStrLn (show (historyEntryId entry) ++ ": " ++ describeEvent (historyEvent entry))
      describeEvent TournamentCreated              = "Tournament created"
      describeEvent TournamentPublished             = "Tournament published"
      describeEvent RegistrationOpened               = "Registration opened"
      describeEvent RegistrationClosedEvent          = "Registration closed"
      describeEvent BracketGenerated                 = "Bracket generated"
      describeEvent TournamentStarted                = "Tournament started"
      describeEvent TournamentCompleted              = "Tournament completed"
      describeEvent (TournamentCancelled reason)     = "Tournament cancelled: " ++ reason
      describeEvent (ConfigurationChanged field)     = "Configuration changed: " ++ describeField field
      describeField FieldName             = "name"
      describeField FieldVisibility       = "visibility"
      describeField FieldFormat           = "format"
      describeField FieldMaxParticipants  = "max participants"

  ("create-team":teamNameStr:captainNameStr:memberStrs) -> do
    let team = Team
          { teamName    = TeamName teamNameStr
          , teamCaptain = Player (PlayerName captainNameStr)
          , teamMembers = map (Player . PlayerName) memberStrs
          }
    outcome <- createTeam team
    liftIO $ case outcome of
      Left err -> putStrLn ("Failed to create team: " ++ show err)
      Right () -> putStrLn "Team created successfully"

  ("register-cod" : tidStr : teamNameStr : captainName : memberNames) ->
    case readMaybe tidStr :: Maybe Int of
      Nothing ->
        liftIO $ putStrLn "tournamentId must be an integer"

      Just tidInt ->
        if null memberNames
          then liftIO $ putStrLn
            "CoD registration requires at least one team member."
          else do
            let captain = Player (PlayerName captainName)

                members =
                  captain : map (Player . PlayerName) memberNames

                team = Team
                  { teamName    = TeamName teamNameStr
                  , teamCaptain = captain
                  , teamMembers = members
                  }

            teamResult <- createTeam team

            case teamResult of
              Left err ->
                liftIO $ putStrLn
                  ("Team creation failed: " ++ show err)

              Right () -> do
                outcome <- registerCodParticipant
                  (TournamentId tidInt)
                  (Squad team)

                liftIO $ case outcome of
                  Left err ->
                    putStrLn
                      ("CoD registration failed: " ++ show err)

                  Right registrationId ->
                    putStrLn
                      ( "CoD team '" ++ teamNameStr
                      ++ "' registered into tournament "
                      ++ show tidInt
                      ++ " with registration "
                      ++ show registrationId
                      )

  ("register-pubg" : tidStr : teamNameStr : captainName : memberNames) ->
    case readMaybe tidStr :: Maybe Int of
      Nothing ->
        liftIO $ putStrLn "tournamentId must be an integer"

      Just tidInt ->
        if null memberNames
          then liftIO $ putStrLn
            "PUBG registration requires at least one team member."
          else do
            let captain = Player (PlayerName captainName)

                members =
                  captain : map (Player . PlayerName) memberNames

                team = Team
                  { teamName    = TeamName teamNameStr
                  , teamCaptain = captain
                  , teamMembers = members
                  }

            teamResult <- createTeam team

            case teamResult of
              Left err ->
                liftIO $ putStrLn
                  ("Team creation failed: " ++ show err)

              Right () -> do
                outcome <- registerPubgParticipant
                  (TournamentId tidInt)
                  (Squad team)

                liftIO $ case outcome of
                  Left err ->
                    putStrLn
                      ("PUBG registration failed: " ++ show err)

                  Right registrationId ->
                    putStrLn
                      ( "PUBG team '" ++ teamNameStr
                      ++ "' registered into tournament "
                      ++ show tidInt
                      ++ " with registration "
                      ++ show registrationId
                      )

  _ -> liftIO $ putStrLn usage

  

usage :: String
usage = unlines
  [ "ArenaOS CLI"
  , "  create-tournament <userId> <name> <organizer> <maxParticipants>"
  , "  register <tournamentId> <playerName>"
  , "  generate-bracket <userId> <tournamentId>"
  , "  list-matches <bracketId>"
  , "  start-match <matchId>"
  , "  record-result <matchId> <A|B>"
  , "  complete-tournament <tournamentId>"
  , "  register-user <username> <email> <password>"
  , "  login <username> <password>"
  , "  logout"
  , "  my-tournaments <userId>"
  , "  change-password <userId> <currentPassword> <newPassword>"
  , "  profile <userId>"
  , "  update-profile <userId> <username> <email>"
  , "  set-account-status <userId> <status>"
  , "  publish-tournament <userId> <tournamentId>"
    , "  open-registration <userId> <tournamentId>"
    , "  close-registration <userId> <tournamentId>"
    , "  start-tournament <userId> <tournamentId>"
    , "  cancel-tournament <userId> <tournamentId> <reason>"
  , "  update-tournament-name <userId> <tournamentId> <name>"
  , "  update-tournament-visibility <userId> <tournamentId> <visibility>"
  , "  update-tournament-format <userId> <tournamentId> <format>"
  , "  update-tournament-max-participants <userId> <tournamentId> <maxParticipants>"
  , "  dashboard"
  , "  history <userId> <tournamentId>"
  , "  create-team <teamName> <captainName> [member1 member2 ...]"
  , "  register-cod <tournamentId> <teamName> <captainName> [member1 member2 ...]"
  , "  register-pubg <tournamentId> <teamName> <captainName> [member1 member2 ...]"
  ]

parseStatus :: String -> Maybe AccountStatus
parseStatus "Active"      = Just Active
parseStatus "Suspended"   = Just Suspended
parseStatus "Deactivated" = Just Deactivated
parseStatus _             = Nothing

parseVisibility :: String -> Maybe Visibility
parseVisibility "Public"  = Just Public
parseVisibility "Private" = Just Private
parseVisibility _         = Nothing

parseFormat :: String -> Maybe TournamentFormat
parseFormat "SingleElimination" = Just SingleElimination
parseFormat "DoubleElimination" = Just DoubleElimination
parseFormat "RoundRobin"        = Just RoundRobin
parseFormat _                   = Nothing

 