{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Test.Hspec
import Control.Monad (forM_)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import System.Directory (doesFileExist, removeFile)

import Shell.Persistence.SQLite.Connection (SQLiteM, SQLiteEnv(envConnection), runSQLiteM)
import Shell.Persistence.SQLite.Schema (initializeSchema)
import qualified Shell.Persistence.Port as Repo
import Shell.Persistence.Port (NewTournament(..), UserId(..), TournamentRepository, NewUser(..), PasswordHasher(..))
import Shell.Persistence.Port hiding
  ( createTournament
  , updateTournamentName
  , updateTournamentVisibility
  , updateTournamentFormat
  , updateTournamentMaxParticipants
  )

import Shell.Persistence.SQLite.ParticipantRepository ()
import Shell.Persistence.SQLite.TournamentRepository ()
import Shell.Persistence.SQLite.RegistrationRepository ()
import Shell.Persistence.SQLite.BracketRepository ()
import Shell.Persistence.SQLite.MatchRepository ()
import Shell.Persistence.SQLite.UserRepository ()
import Shell.Persistence.SQLite.TournamentHistoryRepository ()

import Domain.Participant (Participant(..), Player(..), PlayerName(..), Team(..), TeamName(..), TeamCaptain(..))
import Domain.Tournament
  ( TournamentName(..), OrganizerName(..), TournamentFormat(..)
  , Visibility(..), TournamentState(..), Tournament(..), TournamentId(..)
  )
import Domain.Match (Match(..), MatchStatus(Scheduled), MatchOutcome(..))
import Domain.User (Email(..), PasswordHash(..), Username(..))

import Application.UseCases.CreateTournament (createTournament)
import Application.UseCases.RegisterParticipant (registerParticipant, RegisterParticipantError(..))
import Application.UseCases.GenerateBracket (generateBracket, GenerateBracketError(..))
import Application.UseCases.StartMatch (startMatch, StartMatchError(..))
import Application.UseCases.RecordMatchResult (recordMatchResult, RecordMatchResultError(..))
import Application.UseCases.CompleteTournament (completeTournament, CompleteTournamentError(..))
import Application.UseCases.PublishTournament (publishTournament, PublishTournamentError(..))
import Application.UseCases.OpenRegistration (openRegistration, OpenRegistrationError(..))
import Application.UseCases.CloseRegistration (closeRegistration, CloseRegistrationError(..))
import Application.UseCases.StartTournament (startTournament, StartTournamentError(..))
import Application.UseCases.CancelTournament (cancelTournament, CancelTournamentError(..))
import Application.Internal.Authorization (AuthorizationError(..))
import Application.Internal.LifecycleTransition (LifecycleError(..))
import Application.UseCases.LogoutUser (logoutUser)
import Shell.Auth.Session (saveSession)
import Data.Either (isLeft)
import Data.Text (Text)
import qualified Application.UseCases.GenerateBracket as GB
import qualified Application.UseCases.RecordMatchResult as RMR
import qualified Application.UseCases.StartMatch as SM
import qualified Application.UseCases.CompleteTournament as CT
import qualified Application.UseCases.PublishTournament as PubT
import qualified Application.UseCases.OpenRegistration as OpenReg
import qualified Application.UseCases.CloseRegistration as CloseReg
import qualified Application.UseCases.StartTournament as ST
import qualified Application.UseCases.CancelTournament as CancelT
import Application.UseCases.UpdateTournamentName (updateTournamentName, UpdateTournamentNameError(..))
import Application.UseCases.UpdateTournamentVisibility (updateTournamentVisibility, UpdateTournamentVisibilityError(..))
import Application.UseCases.UpdateTournamentMaxParticipants (updateTournamentMaxParticipants, UpdateTournamentMaxParticipantsError(..))
import Application.UseCases.UpdateTournamentFormat (updateTournamentFormat, UpdateTournamentFormatError(..))
import Application.UseCases.GetOrganizerDashboard (getOrganizerDashboard, GetOrganizerDashboardError(..), OrganizerDashboard(..), StateCounts(..), buildDashboard)
import qualified Application.UseCases.UpdateTournamentName as UTN
import qualified Application.UseCases.UpdateTournamentVisibility as UTV
import qualified Application.UseCases.UpdateTournamentMaxParticipants as UTM
import qualified Application.UseCases.UpdateTournamentFormat as UTF
import Application.UseCases.CreateTeam (createTeam, CreateTeamError(..))
import Application.UseCases.RegisterCodParticipant (registerCodParticipant, RegisterCodParticipantError(..))
import Application.UseCases.RegisterPubgParticipant (registerPubgParticipant, RegisterPubgParticipantError(..))

testDbPath :: FilePath
testDbPath = "test/arenaos-test.db"

resetTestDb :: IO ()
resetTestDb = do
  exists <- doesFileExist testDbPath
  if exists then removeFile testDbPath else pure ()

setupSchema :: SQLiteM ()
setupSchema = do
  env <- ask
  liftIO $ initializeSchema (envConnection env)

createTestUser :: Text -> SQLiteM UserId
createTestUser label = Repo.createUser NewUser
  { newUserUsername     = Username label
  , newUserEmail        = Email (label <> "@test.com")
  , newUserPasswordHash = PasswordHash "test-hash"
  }

unwrap :: Show e => Either e a -> SQLiteM a
unwrap (Right a) = pure a
unwrap (Left e)  = liftIO $ do
  expectationFailure (show e)
  error "unreachable"

-- Advances a freshly-created (Draft) tournament to RegistrationOpen.
-- Needed before any registerParticipant call now that FR-TM-009's
-- retrofit gates registration on TournamentState == RegistrationOpen.
advanceToRegistrationOpen :: UserId -> TournamentId -> SQLiteM ()
advanceToRegistrationOpen ownerId tid = do
  _ <- unwrap =<< publishTournament ownerId tid
  _ <- unwrap =<< openRegistration ownerId tid
  pure ()

-- Advances a freshly-created (Draft) tournament through Published ->
-- RegistrationOpen -> RegistrationClosed. Needed by every existing
-- v0.1/v0.2 test that calls generateBracket, now that FR-LIFE-004
-- requires RegistrationClosed as a precondition -- those tests
-- previously ran generateBracket straight off Draft, which is no
-- longer valid. NOTE: as of the FR-TM-009 retrofit, any
-- registerParticipant calls must happen strictly between
-- advanceToRegistrationOpen and this function's closeRegistration
-- step -- registration is no longer legal in Draft.
advanceToRegistrationClosed :: UserId -> TournamentId -> SQLiteM ()
advanceToRegistrationClosed ownerId tid = do
  advanceToRegistrationOpen ownerId tid
  _ <- unwrap =<< closeRegistration ownerId tid
  pure ()

main :: IO ()
main = hspec spec

spec :: Spec
spec = before_ resetTestDb $ do

  describe "Tournament Lifecycle (4-participant golden scenario)" $
    it "runs the full pipeline from creation to completion" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"

        let participants =
              [ Individual (Player (PlayerName "Alice"))
              , Individual (Player (PlayerName "Bob"))
              , Individual (Player (PlayerName "Carol"))
              , Individual (Player (PlayerName "Dave"))
              ]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Golden Test Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 4
          }

        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team

        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid

        bracketId <- unwrap =<< generateBracket ownerId tid

        semiMatches <- Repo.listMatchesForBracket bracketId
        liftIO $ length semiMatches `shouldBe` 2

        forM_ semiMatches $ \m -> do
          _ <- unwrap =<< startMatch ownerId (matchId m)
          _ <- unwrap =<< recordMatchResult ownerId (matchId m) (Winner (matchCompetitorA m))
          pure ()

        allMatches <- Repo.listMatchesForBracket bracketId
        let finalMatches = filter (\m -> matchStatus m == Scheduled) allMatches
        liftIO $ length finalMatches `shouldBe` 1
        let finalMatch = head finalMatches

        _ <- unwrap =<< startMatch ownerId (matchId finalMatch)
        _ <- unwrap =<< recordMatchResult ownerId (matchId finalMatch) (Winner (matchCompetitorA finalMatch))

        _ <- unwrap =<< startTournament ownerId tid
        unwrap =<< completeTournament ownerId tid

      case result of
        Left err         -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right tournament -> tournamentState tournament `shouldBe` Completed

  describe "Bye-path scenario (3 participants)" $
    it "gives the earliest-registered participant a bye and completes the tournament" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"

        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            carol = Individual (Player (PlayerName "Carol"))
            participants = [alice, bob, carol]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Bye Test Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 3
          }

        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team

        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid

        bracketId <- unwrap =<< generateBracket ownerId tid

        semiMatches <- Repo.listMatchesForBracket bracketId
        liftIO $ length semiMatches `shouldBe` 1
        let semiMatch = head semiMatches
        liftIO $ matchCompetitorA semiMatch `shouldBe` bob
        liftIO $ matchCompetitorB semiMatch `shouldBe` carol

        _ <- unwrap =<< startMatch ownerId (matchId semiMatch)
        _ <- unwrap =<< recordMatchResult ownerId (matchId semiMatch) (Winner (matchCompetitorB semiMatch))

        allMatches <- Repo.listMatchesForBracket bracketId
        let finalMatches = filter (\m -> matchStatus m == Scheduled) allMatches
        liftIO $ length finalMatches `shouldBe` 1
        let finalMatch = head finalMatches
        liftIO $ [matchCompetitorA finalMatch, matchCompetitorB finalMatch]
          `shouldMatchList` [alice, carol]

        _ <- unwrap =<< startMatch ownerId (matchId finalMatch)
        _ <- unwrap =<< recordMatchResult ownerId (matchId finalMatch) (Winner (matchCompetitorA finalMatch))

        _ <- unwrap =<< startTournament ownerId tid
        unwrap =<< completeTournament ownerId tid

      case result of
        Left err         -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right tournament -> tournamentState tournament `shouldBe` Completed

  describe "Error paths" $ do
    it "rejects starting a match that's already been started" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Error Test Cup A"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        matches <- Repo.listMatchesForBracket bracketId
        let m = head matches

        _ <- unwrap =<< startMatch ownerId (matchId m)
        secondStart <- startMatch ownerId (matchId m)
        pure secondStart

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldSatisfy` isLeft

    it "rejects recording a result before the match is started" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Error Test Cup B"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        matches <- Repo.listMatchesForBracket bracketId
        let m = head matches

        recordMatchResult ownerId (matchId m) (Winner (matchCompetitorA m))

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldSatisfy` isLeft

    it "rejects a winner who isn't a competitor in the match" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            eve   = Individual (Player (PlayerName "Eve"))
            participants = [alice, bob]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Error Test Cup C"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        case eve of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        otherTid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Unrelated Tournament"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        advanceToRegistrationOpen ownerId otherTid
        _ <- unwrap =<< registerParticipant otherTid eve
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        matches <- Repo.listMatchesForBracket bracketId
        let m = head matches

        _ <- unwrap =<< startMatch ownerId (matchId m)
        recordMatchResult ownerId (matchId m) (Winner eve)

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldSatisfy` isLeft

    it "rejects completing a tournament with a match still pending" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Error Test Cup D"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        _ <- unwrap =<< generateBracket ownerId tid

        completeTournament ownerId tid

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldSatisfy` isLeft

    it "rejects generating a bracket when the caller isn't the tournament owner" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId    <- createTestUser "owner"
        impostorId <- createTestUser "impostor"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Ownership Test Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        -- Not advanced to RegistrationClosed on purpose: authorization
        -- runs before the state check (FR-LIFE-006 / the same ordering
        -- as v0.2), so an impostor is rejected regardless of state.
        generateBracket impostorId tid

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left (GB.Unauthorized NotTournamentOwner)

    it "rejects recording a match result when the caller isn't the tournament owner" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId    <- createTestUser "owner"
        impostorId <- createTestUser "impostor"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Ownership Test Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        matches <- Repo.listMatchesForBracket bracketId
        let m = head matches

        recordMatchResult impostorId (matchId m) (Winner (matchCompetitorA m))

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left (RMR.Unauthorized NotTournamentOwner)

    it "rejects completing a tournament when the caller isn't the tournament owner" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId    <- createTestUser "owner"
        impostorId <- createTestUser "impostor"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Ownership Test Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        _ <- unwrap =<< generateBracket ownerId tid

        completeTournament impostorId tid

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left (CT.Unauthorized NotTournamentOwner)

  -- FR-LIFE: Tournament Lifecycle Management
  describe "Tournament Lifecycle Transitions (FR-LIFE)" $ do

    it "walks a tournament through every forward transition in order" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Lifecycle Walk Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        _ <- unwrap =<< publishTournament ownerId tid
        _ <- unwrap =<< openRegistration ownerId tid

        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
        Repo.savePlayer (Player (PlayerName "Alice"))
        Repo.savePlayer (Player (PlayerName "Bob"))
        -- Registration must happen here, between RegistrationOpen and
        -- CloseRegistration, now that FR-TM-009's retrofit gates
        -- registerParticipant on TournamentState == RegistrationOpen.
        _ <- unwrap =<< registerParticipant tid alice
        _ <- unwrap =<< registerParticipant tid bob

        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        _ <- unwrap =<< startTournament ownerId tid

        Repo.getTournament tid

      case result of
        Left err         -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right tournament -> tournamentState tournament `shouldBe` InProgress

    it "rejects an out-of-order transition (CloseRegistration from Draft)" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Out Of Order Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        closeRegistration ownerId tid

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe`
          Left (CloseReg.InvalidLifecycle (InvalidTransition Draft RegistrationOpen))

    it "rejects a lifecycle transition when the caller isn't the tournament owner" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId    <- createTestUser "owner"
        impostorId <- createTestUser "impostor"
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Lifecycle Ownership Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        publishTournament impostorId tid

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left (PubT.Unauthorized NotTournamentOwner)

    it "rejects GenerateBracket when the tournament isn't RegistrationClosed" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Early Bracket Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        -- Deliberately still RegistrationOpen, not Closed.
        generateBracket ownerId tid

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe`
          Left (GB.InvalidLifecycle (InvalidTransition RegistrationOpen RegistrationClosed))

    it "rejects StartTournament when no bracket has been generated" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "No Bracket Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        advanceToRegistrationClosed ownerId tid
        startTournament ownerId tid

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left ST.BracketNotGenerated

    it "allows StartTournament once a bracket exists" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Ready To Start Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        _ <- unwrap =<< generateBracket ownerId tid
        _ <- unwrap =<< startTournament ownerId tid
        Repo.getTournament tid

      case result of
        Left err         -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right tournament -> tournamentState tournament `shouldBe` InProgress

    it "allows cancellation from every non-terminal state" $ do
      -- Draft, Published, RegistrationOpen, RegistrationClosed, InProgress
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"

        tidDraft <- createTournament NewTournament
          { newTournamentName = TournamentName "Cancel From Draft"
          , newTournamentOrganizer = OrganizerName "Test Organizer", newTournamentOwner = ownerId
          , newTournamentFormat = SingleElimination, newTournamentVisibility = Public
          , newTournamentMaxParticipants = 2 }
        _ <- unwrap =<< cancelTournament ownerId tidDraft "no longer needed"

        tidPublished <- createTournament NewTournament
          { newTournamentName = TournamentName "Cancel From Published"
          , newTournamentOrganizer = OrganizerName "Test Organizer", newTournamentOwner = ownerId
          , newTournamentFormat = SingleElimination, newTournamentVisibility = Public
          , newTournamentMaxParticipants = 2 }
        _ <- unwrap =<< publishTournament ownerId tidPublished
        _ <- unwrap =<< cancelTournament ownerId tidPublished "no longer needed"

        tidRegOpen <- createTournament NewTournament
          { newTournamentName = TournamentName "Cancel From RegOpen"
          , newTournamentOrganizer = OrganizerName "Test Organizer", newTournamentOwner = ownerId
          , newTournamentFormat = SingleElimination, newTournamentVisibility = Public
          , newTournamentMaxParticipants = 2 }
        _ <- unwrap =<< publishTournament ownerId tidRegOpen
        _ <- unwrap =<< openRegistration ownerId tidRegOpen
        _ <- unwrap =<< cancelTournament ownerId tidRegOpen "no longer needed"

        tidRegClosed <- createTournament NewTournament
          { newTournamentName = TournamentName "Cancel From RegClosed"
          , newTournamentOrganizer = OrganizerName "Test Organizer", newTournamentOwner = ownerId
          , newTournamentFormat = SingleElimination, newTournamentVisibility = Public
          , newTournamentMaxParticipants = 2 }
        advanceToRegistrationClosed ownerId tidRegClosed
        _ <- unwrap =<< cancelTournament ownerId tidRegClosed "no longer needed"

        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tidInProgress <- createTournament NewTournament
          { newTournamentName = TournamentName "Cancel From InProgress"
          , newTournamentOrganizer = OrganizerName "Test Organizer", newTournamentOwner = ownerId
          , newTournamentFormat = SingleElimination, newTournamentVisibility = Public
          , newTournamentMaxParticipants = 2 }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tidInProgress
        forM_ participants (\p -> unwrap =<< registerParticipant tidInProgress p)
        _ <- unwrap =<< closeRegistration ownerId tidInProgress
        _ <- unwrap =<< generateBracket ownerId tidInProgress
        _ <- unwrap =<< startTournament ownerId tidInProgress
        _ <- unwrap =<< cancelTournament ownerId tidInProgress "no longer needed"

        states <- mapM Repo.getTournament
          [tidDraft, tidPublished, tidRegOpen, tidRegClosed, tidInProgress]
        pure (map tournamentState states)

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right states -> states `shouldBe` replicate 5 Cancelled

    it "rejects cancelling a Completed tournament" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Completed Cancel Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        matches <- Repo.listMatchesForBracket bracketId
        let m = head matches
        _ <- unwrap =<< startTournament ownerId tid
        _ <- unwrap =<< startMatch ownerId (matchId m)
        _ <- unwrap =<< recordMatchResult ownerId (matchId m) (Winner (matchCompetitorA m))
        _ <- unwrap =<< completeTournament ownerId tid

        cancelTournament ownerId tid "changed my mind"

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left (CancelT.InvalidLifecycle (ForbiddenState Completed))

    it "rejects cancelling an already-Cancelled tournament" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Double Cancel Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        _ <- unwrap =<< cancelTournament ownerId tid "first cancellation"
        cancelTournament ownerId tid "second cancellation"

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left (CancelT.InvalidLifecycle (ForbiddenState Cancelled))

    it "rejects an empty cancellation reason" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Empty Reason Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        cancelTournament ownerId tid ""

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left CancelT.EmptyCancellationReason

  describe "Tournament Editing (FR-EDIT)" $ do

    it "allows the owner to update the name while in Draft" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Original Name"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 8
          }
        _ <- unwrap =<< updateTournamentName ownerId tid (TournamentName "Renamed Cup")
        Repo.getTournament tid

      case result of
        Left err         -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right tournament -> tournamentName tournament `shouldBe` TournamentName "Renamed Cup"

    it "allows edits through every editable state (Published, RegistrationOpen, RegistrationClosed)" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Multi-State Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 8
          }
        _ <- unwrap =<< publishTournament ownerId tid
        _ <- unwrap =<< updateTournamentVisibility ownerId tid Private
        _ <- unwrap =<< openRegistration ownerId tid
        _ <- unwrap =<< updateTournamentFormat ownerId tid DoubleElimination
        _ <- unwrap =<< closeRegistration ownerId tid
        _ <- unwrap =<< updateTournamentMaxParticipants ownerId tid 16
        Repo.getTournament tid

      case result of
        Left err         -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right tournament -> do
          tournamentVisibility tournament `shouldBe` Private
          tournamentFormat tournament `shouldBe` DoubleElimination
          tournamentMaxParticipants tournament `shouldBe` 16

    it "rejects editing a tournament that's InProgress" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "In Progress Edit Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        _ <- unwrap =<< generateBracket ownerId tid
        _ <- unwrap =<< startTournament ownerId tid

        updateTournamentName ownerId tid (TournamentName "Too Late")

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe`
          Left (UTN.InvalidLifecycle (ForbiddenState InProgress))

    it "rejects editing a Completed tournament" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Completed Edit Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        matches <- Repo.listMatchesForBracket bracketId
        let m = head matches
        _ <- unwrap =<< startTournament ownerId tid
        _ <- unwrap =<< startMatch ownerId (matchId m)
        _ <- unwrap =<< recordMatchResult ownerId (matchId m) (Winner (matchCompetitorA m))
        _ <- unwrap =<< completeTournament ownerId tid

        updateTournamentVisibility ownerId tid Private

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe`
          Left (UTV.InvalidLifecycle (ForbiddenState Completed))

    it "rejects editing a Cancelled tournament" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Cancelled Edit Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        _ <- unwrap =<< cancelTournament ownerId tid "no longer needed"

        updateTournamentFormat ownerId tid DoubleElimination

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe`
          Left (UTF.InvalidLifecycle (ForbiddenState Cancelled))

    it "rejects an edit from a non-owner" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId    <- createTestUser "owner"
        impostorId <- createTestUser "impostor"
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Edit Ownership Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        updateTournamentName impostorId tid (TournamentName "Hijacked")

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left (UTN.Unauthorized NotTournamentOwner)

    it "rejects reducing MaxParticipants below current registration count" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            carol = Individual (Player (PlayerName "Carol"))
            participants = [alice, bob, carol]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Floor Test Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 8
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)

        updateTournamentMaxParticipants ownerId tid 2

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left UTM.BelowRegistrationCount

    it "allows reducing MaxParticipants to exactly the current registration count" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Floor Boundary Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 8
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< updateTournamentMaxParticipants ownerId tid 2
        Repo.getTournament tid

      case result of
        Left err         -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right tournament -> tournamentMaxParticipants tournament `shouldBe` 2

  describe "Organizer Dashboard (FR-DASH)" $ do

    it "aggregates state counts correctly from a fixed tournament list (pure)" $ do
      let mkT s = Tournament
            { tournamentId = TournamentId 0
            , tournamentName = TournamentName "x"
            , tournamentOrganizer = OrganizerName "x"
            , tournamentFormat = SingleElimination
            , tournamentState = s
            , tournamentVisibility = Public
            , tournamentMaxParticipants = 2
            , tournamentBracket = Nothing
            , tournamentOwner = UserId 1
            }
          tournaments = map mkT [Draft, Draft, Published, InProgress, Completed, Completed, Completed, Cancelled]
          dashboard = buildDashboard tournaments
      dashboardCounts dashboard `shouldBe` StateCounts
        { countDraft = 2, countPublished = 1, countRegistrationOpen = 0
        , countRegistrationClosed = 0, countInProgress = 1, countCompleted = 3, countCancelled = 1 }
      length (dashboardTournaments dashboard) `shouldBe` 8

    it "returns SessionAbsent when no one is logged in" $ do
      liftIO logoutUser  -- ensure no session file exists
      result <- runSQLiteM testDbPath $ do
        setupSchema
        getOrganizerDashboard
      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left SessionAbsent

    it "returns a dashboard reflecting only the logged-in owner's tournaments" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "dashowner"
        otherId <- createTestUser "otherowner"
        _ <- createTournament NewTournament
          { newTournamentName = TournamentName "Mine 1", newTournamentOrganizer = OrganizerName "x"
          , newTournamentOwner = ownerId, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 2 }
        _ <- createTournament NewTournament
          { newTournamentName = TournamentName "Not Mine", newTournamentOrganizer = OrganizerName "x"
          , newTournamentOwner = otherId, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 2 }
        liftIO $ saveSession ownerId
        getOrganizerDashboard

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> case inner of
          Left dashErr -> expectationFailure (show dashErr)
          Right dash   -> length (dashboardTournaments dash) `shouldBe` 1

  describe "Team Creation (FR-TEAMOPS)" $ do

    it "creates a team when the captain is included in the member list" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        let captain = Player (PlayerName "Alice")
            bob     = Player (PlayerName "Bob")
            team = Team
              { teamName    = TeamName "Alpha Squad"
              , teamCaptain = captain
              , teamMembers = [captain, bob]
              }
        _ <- unwrap =<< createTeam team
        Repo.getTeam (TeamName "Alpha Squad")

      case result of
        Left err       -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right gotTeam  -> do
          teamName gotTeam `shouldBe` TeamName "Alpha Squad"
          teamCaptain gotTeam `shouldBe` Player (PlayerName "Alice")
          teamMembers gotTeam `shouldMatchList`
            [Player (PlayerName "Alice"), Player (PlayerName "Bob")]

    it "rejects team creation when the captain isn't in the member list" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        let captain = Player (PlayerName "Alice")
            bob     = Player (PlayerName "Bob")
            team = Team
              { teamName    = TeamName "Beta Squad"
              , teamCaptain = captain
              , teamMembers = [bob]
              }
        createTeam team

      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldBe` Left CaptainNotInMembers

    it "rejects creating a team with a name that already exists" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        let captain = Player (PlayerName "Alice")
            team = Team
              { teamName    = TeamName "Gamma Squad"
              , teamCaptain = captain
              , teamMembers = [captain]
              }
        _ <- unwrap =<< createTeam team
        createTeam team  -- second call, same name

      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldBe` Left (TeamNameAlreadyExists (TeamName "Gamma Squad"))

    it "allows a team whose only member is the captain" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        let captain = Player (PlayerName "Solo Captain")
            team = Team
              { teamName    = TeamName "Solo Squad"
              , teamCaptain = captain
              , teamMembers = [captain]
              }
        _ <- unwrap =<< createTeam team
        Repo.getTeam (TeamName "Solo Squad")

      case result of
        Left err      -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right gotTeam -> teamMembers gotTeam `shouldBe` [Player (PlayerName "Solo Captain")]

  describe "Registration Validation (FR-TM-009)" $ do

    it "rejects registration when the tournament isn't RegistrationOpen" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Draft Registration Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        let alice = Individual (Player (PlayerName "Alice"))
        Repo.savePlayer (Player (PlayerName "Alice"))
        -- Deliberately still Draft -- no lifecycle advancement.
        registerParticipant tid alice

      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldBe`
          Left (RegistrationLifecycleError (InvalidTransition Draft RegistrationOpen))

    it "rejects registration once MaxParticipants is reached" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            carol = Individual (Player (PlayerName "Carol"))
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Capacity Test Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        forM_ [alice, bob, carol] $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        _ <- unwrap =<< registerParticipant tid alice
        _ <- unwrap =<< registerParticipant tid bob
        registerParticipant tid carol  -- third registration, max is 2

      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldBe` Left RegistrationCapacityReached
   
  describe "CoD Registration (FR-CODOPS)" $ do

    it "rejects an Individual participant" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "CoD Solo Rejection Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        advanceToRegistrationOpen ownerId tid
        let alice = Individual (Player (PlayerName "Alice"))
        Repo.savePlayer (Player (PlayerName "Alice"))
        registerCodParticipant tid alice

      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldBe` Left CodRequiresTeam

    it "accepts a Squad participant and delegates through the real registration pipeline" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        let captain = Player (PlayerName "Alice")
            bob     = Player (PlayerName "Bob")
            team = Team
              { teamName    = TeamName "CoD Alpha Squad"
              , teamCaptain = captain
              , teamMembers = [captain, bob]
              }
        _ <- unwrap =<< createTeam team
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "CoD Squad Accept Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        advanceToRegistrationOpen ownerId tid
        _ <- unwrap =<< registerCodParticipant tid (Squad team)
        Repo.listRegistrations tid

      case result of
        Left err            -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right registrations -> length registrations `shouldBe` 1

    it "rejects a Squad participant when the tournament isn't RegistrationOpen, via the delegated pipeline" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        let captain = Player (PlayerName "Alice")
            team = Team
              { teamName    = TeamName "CoD Beta Squad"
              , teamCaptain = captain
              , teamMembers = [captain]
              }
        _ <- unwrap =<< createTeam team
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "CoD Draft Rejection Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        -- Deliberately still Draft -- no lifecycle advancement.
        registerCodParticipant tid (Squad team)

      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldBe`
          Left (CodRegistrationError (RegistrationLifecycleError (InvalidTransition Draft RegistrationOpen)))
  describe "PUBG Registration (FR-PUBGOPS)" $ do

    it "rejects an Individual participant" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "PUBG Solo Rejection Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        advanceToRegistrationOpen ownerId tid
        let alice = Individual (Player (PlayerName "Alice"))
        Repo.savePlayer (Player (PlayerName "Alice"))
        registerPubgParticipant tid alice

      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldBe` Left PubgRequiresTeam

    it "accepts a Squad participant and delegates through the real registration pipeline" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        let captain = Player (PlayerName "Alice")
            bob     = Player (PlayerName "Bob")
            team = Team
              { teamName    = TeamName "PUBG Alpha Squad"
              , teamCaptain = captain
              , teamMembers = [captain, bob]
              }
        _ <- unwrap =<< createTeam team
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "PUBG Squad Accept Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        advanceToRegistrationOpen ownerId tid
        _ <- unwrap =<< registerPubgParticipant tid (Squad team)
        Repo.listRegistrations tid

      case result of
        Left err            -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right registrations -> length registrations `shouldBe` 1

    it "rejects a Squad participant when the tournament isn't RegistrationOpen, via the delegated pipeline" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        let captain = Player (PlayerName "Alice")
            team = Team
              { teamName    = TeamName "PUBG Beta Squad"
              , teamCaptain = captain
              , teamMembers = [captain]
              }
        _ <- unwrap =<< createTeam team
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "PUBG Draft Rejection Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        -- Deliberately still Draft -- no lifecycle advancement.
        registerPubgParticipant tid (Squad team)

      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldBe`
          Left (PubgRegistrationError (RegistrationLifecycleError (InvalidTransition Draft RegistrationOpen)))