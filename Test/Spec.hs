{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Test.Hspec
import Control.Monad (forM_)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import System.Directory (doesFileExist, removeFile)
import Data.Time (getCurrentTime)
import Data.Maybe(isJust)
import Data.List(find)
import Data.Either (isLeft, isRight)

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
import Shell.Persistence.SQLite.RoleRepository ()
import Shell.Persistence.SQLite.AuditLogRepository ()

import Domain.Participant (Participant(..), Player(..), PlayerName(..), Team(..), TeamName(..), TeamCaptain(..))
import Domain.Tournament
  ( TournamentName(..), OrganizerName(..), TournamentFormat(..)
  , Visibility(..), TournamentState(..), Tournament(..), TournamentId(..)
  )
import Domain.Match (Match(..),MatchId(..), MatchStatus(Scheduled), MatchOutcome(..))
import Domain.User (User(..),Email(..), PasswordHash(..), Username(..), AccountStatus(..))
import Domain.MatchError (MatchError(..))
import qualified Domain.Match as Match
import Domain.TournamentError (TournamentError(..))

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
import Application.UseCases.GetOrganizerDashboard (getOrganizerDashboard, GetOrganizerDashboardError(..))
import qualified Application.UseCases.UpdateTournamentName as UTN
import qualified Application.UseCases.UpdateTournamentVisibility as UTV
import qualified Application.UseCases.UpdateTournamentMaxParticipants as UTM
import qualified Application.UseCases.UpdateTournamentFormat as UTF
import Application.UseCases.CreateTeam (createTeam, CreateTeamError(..))
import Application.UseCases.RegisterCodParticipant (registerCodParticipant, RegisterCodParticipantError(..))
import Application.UseCases.RegisterPubgParticipant (registerPubgParticipant, RegisterPubgParticipantError(..))
import Application.UseCases.RegisterTeamOnly (registerTeamOnly, RegisterTeamOnlyError(..))
import Domain.Role (Role(..))
import Application.UseCases.GrantRole (grantRole, GrantRoleError(..))
import Application.UseCases.RevokeRole (revokeRole, RevokeRoleError(..))
import Application.Internal.Authorization (AuthorizationError(..), requireAdministrator)
import Application.UseCases.SetAccountStatus (setAccountStatus, SetAccountStatusRequest(..), SetAccountStatusError(..))
import qualified Application.UseCases.SetAccountStatus as SAS
import Application.UseCases.GetAdministratorDashboard
  (getAdministratorDashboard, GetAdministratorDashboardError(..))
import Application.Internal.TournamentOverview (TournamentOverview(..), StateCounts(..), buildTournamentOverview)
import qualified Application.UseCases.GetAdministratorDashboard as GAD
import qualified Application.UseCases.GrantRole as GR
import qualified Application.UseCases.RevokeRole as RR
import Domain.Audit (AuditEvent(..), AuditOperation(..))
import Application.UseCases.RecordEFootballResult
  (recordEFootballResult, RecordEFootballResultError(..))
import Domain.Scoreable (mkEFootballScore)
import Shell.Persistence.SQLite.EFootballScoreRepository ()
import qualified Engine.BracketGeneration as BracketGeneration
import qualified Engine.Seeding           as Seeding
import Domain.Bracket (BracketNode(..), BracketNodeId(..), BracketSide(..), MatchSlot(..),BracketId(..))
import Application.UseCases.GetRoundRobinStandings (getRoundRobinStandings, GetRoundRobinStandingsError(..))
import Engine.Standings (Standing(..))
import qualified Engine.Standings as Standings
import qualified Application.UseCases.GetRoundRobinStandings as GRRS
import qualified Application.UseCases.GetRoundRobinStandings as GetRoundRobinStandings
import Application.UseCases.CorrectMatchResult(correctMatchResult,CorrectMatchResultError(..))
import System.IO (hSetBuffering, stdout, BufferMode(LineBuffering))



data TestTxError = TestTxError deriving (Eq, Show)
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
main = do
  hSetBuffering stdout LineBuffering
  hspec spec

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

  describe "Single Elim Completion Invariant (v0.8.3)" $ do
    it "rejects completion when the root/final match has not been played (8 participants, R2 unplayed)" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "se-completion-owner"
        let participants =
              [ Individual (Player (PlayerName ("P" ++ show i))) | i <- [1 .. 8 :: Int] ]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "SE Completion Invariant Cup"
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
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid

        (_, nodesAtGen) <- Repo.getBracket bracketId
        let round1NodeIds = map nodeId (filter ((== 1) . nodeRound) nodesAtGen)

        let playMatch m = do
              _ <- unwrap =<< startMatch ownerId (matchId m)
              unwrap =<< recordMatchResult ownerId (matchId m) (Winner (matchCompetitorA m))

        -- Complete every round-1 match specifically -- located by NODE
        -- round, not list position or count, per Case B's lesson that
        -- materialized-match counts can include automatically resolved
        -- structure we shouldn't assume away.
        r1AtStart <- Repo.listMatchesForBracket bracketId
        let r1Matches = filter (\m -> matchBracketNode m `elem` round1NodeIds) r1AtStart
        mapM_ playMatch r1Matches

        -- Deliberately do NOT play round 2. The unique root/final match
        -- (highest nodeRound, per buildTopology's construction) must not
        -- have a Completed outcome at this point.
        _ <- unwrap =<< startTournament ownerId tid

        tournamentBefore <- Repo.getTournament tid
        outcome <- completeTournament ownerId tid
        tournamentAfter <- Repo.getTournament tid

        pure (outcome, tournamentBefore, tournamentAfter)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, tournamentBefore, tournamentAfter) -> do
          outcome `shouldBe` Left (CT.InvalidCompletion TournamentNotComplete)
          tournamentState tournamentBefore `shouldBe` InProgress
          tournamentState tournamentAfter  `shouldBe` InProgress


    it "completes an 8-participant Single Elim bracket end-to-end through real advancement" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "se-n8-completion-owner"
        let participants =
              [ Individual (Player (PlayerName ("P" ++ show i))) | i <- [1 .. 8 :: Int] ]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "N8 Completion Cup"
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
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid

        let playMatch m = do
              _ <- unwrap =<< startMatch ownerId (matchId m)
              unwrap =<< recordMatchResult ownerId (matchId m) (Winner (matchCompetitorA m))

        -- Round 1: 4 matches, no advancement help -- just play what's there.
        r1 <- Repo.listMatchesForBracket bracketId
        liftIO $ length r1 `shouldBe` 4
        mapM_ playMatch r1

        -- Round 2 materialized purely by the normal advancement pipeline
        -- (propagateWinner + readyNodes + materializeMatch), not manufactured.
        afterR1 <- Repo.listMatchesForBracket bracketId
        let r2 = filter (\m -> matchStatus m == Scheduled) afterR1
        liftIO $ length r2 `shouldBe` 2
        mapM_ playMatch r2

        -- The final, same story -- materialized by advancement alone.
        afterR2 <- Repo.listMatchesForBracket bracketId
        let final = filter (\m -> matchStatus m == Scheduled) afterR2
        liftIO $ length final `shouldBe` 1
        let finalMatch = head final
            champion   = matchCompetitorA finalMatch   -- always the recorded winner, per playMatch
        _ <- playMatch finalMatch

        _ <- unwrap =<< startTournament ownerId tid
        outcome <- completeTournament ownerId tid

        finalAfter <- Repo.getMatch (matchId finalMatch)

        pure (outcome, champion, finalAfter)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, champion, finalAfter) -> do
          outcome `shouldSatisfy` isRight
          case outcome of
            Right tournament -> tournamentState tournament `shouldBe` Completed
            Left _            -> expectationFailure "completion unexpectedly rejected"
          matchOutcome finalAfter `shouldBe` Just (Winner champion)

    

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

    it "rejects a Draw outcome for a bracket match" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Draw Reject Cup"
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

        outcome    <- recordMatchResult ownerId (matchId m) Draw
        afterMatch <- Repo.getMatch (matchId m)
        pure (outcome, afterMatch)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, afterMatch) -> do
          outcome `shouldBe` Left (RMR.InvalidMatch (OutcomeNotAdvanceable Draw))
          matchStatus  afterMatch `shouldBe` Match.InProgress
          matchOutcome afterMatch `shouldBe` Nothing

    it "rejects a NoContest outcome for a bracket match" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "NoContest Reject Cup"
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

        outcome    <- recordMatchResult ownerId (matchId m) NoContest
        afterMatch <- Repo.getMatch (matchId m)
        pure (outcome, afterMatch)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, afterMatch) -> do
          outcome `shouldBe` Left (RMR.InvalidMatch (OutcomeNotAdvanceable NoContest))
          matchStatus  afterMatch `shouldBe` Match.InProgress
          matchOutcome afterMatch `shouldBe` Nothing

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
          overview = buildTournamentOverview tournaments
      overviewCounts overview `shouldBe` StateCounts
        { countDraft = 2, countPublished = 1, countRegistrationOpen = 0
        , countRegistrationClosed = 0, countInProgress = 1, countCompleted = 3, countCancelled = 1 }
      length (overviewTournaments overview) `shouldBe` 8

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
          Right dash -> length (overviewTournaments dash) `shouldBe` 1
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

  describe "Team-Only Registration (REG-AB-001)" $ do

    it "rejects an Individual participant" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Team Only Solo Rejection Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }

        advanceToRegistrationOpen ownerId tid

        let alice = Individual (Player (PlayerName "Alice"))

        Repo.savePlayer (Player (PlayerName "Alice"))
        registerTeamOnly tid alice

      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldBe` Left RequiresTeam


    it "accepts a Squad participant and delegates through the real registration pipeline" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "owner"

        let captain = Player (PlayerName "Alice")
            bob     = Player (PlayerName "Bob")

            team = Team
              { teamName    = TeamName "Team Only Alpha Squad"
              , teamCaptain = captain
              , teamMembers = [captain, bob]
              }

        _ <- unwrap =<< createTeam team

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Team Only Squad Accept Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }

        advanceToRegistrationOpen ownerId tid

        _ <- unwrap =<< registerTeamOnly tid (Squad team)

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
              { teamName    = TeamName "Team Only Beta Squad"
              , teamCaptain = captain
              , teamMembers = [captain]
              }

        _ <- unwrap =<< createTeam team

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Team Only Draft Rejection Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }

        -- Deliberately still Draft. No lifecycle advancement.
        registerTeamOnly tid (Squad team)

      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldBe`
          Left
            (RegistrationError
              (RegistrationLifecycleError
                (InvalidTransition Draft RegistrationOpen)))

  describe "RoleRepository adapter (Thread 8)" $ do

    it "returns [] for a user with no persisted roles" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        uid <- createTestUser "plain"
        Repo.getRoles uid
      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right roles -> roles `shouldBe` []

    it "returns the granted role after insertRoleMembership" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        uid <- createTestUser "insertable"
        Repo.insertRoleMembership uid Administrator
        Repo.getRoles uid
      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right roles -> roles `shouldBe` [Administrator]

    it "rejects a duplicate insertRoleMembership at the persistence layer" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        uid <- createTestUser "raw-duplicate"
        Repo.insertRoleMembership uid Administrator
        Repo.insertRoleMembership uid Administrator
      result `shouldSatisfy` isLeft

    it "throws NotFound when deleteRoleMembership targets an absent membership" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        uid <- createTestUser "raw-absent"
        Repo.deleteRoleMembership uid Administrator
      result `shouldSatisfy` isLeft

    it "keeps role memberships isolated per user" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        alice <- createTestUser "alice-admin"
        bob   <- createTestUser "bob-plain"
        Repo.insertRoleMembership alice Administrator
        aliceRoles <- Repo.getRoles alice
        bobRoles   <- Repo.getRoles bob
        pure (aliceRoles, bobRoles)
      case result of
        Left err                       -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (aliceRoles, bobRoles)   -> do
          aliceRoles `shouldBe` [Administrator]
          bobRoles   `shouldBe` []

  describe "GrantRole / RevokeRole use cases" $ do

    it "grants a role to a user with no existing roles" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        admin     <- createTestUser "seed-admin"
        candidate <- createTestUser "candidate"
        Repo.insertRoleMembership admin Administrator
        outcome <- grantRole admin candidate Administrator
        roles   <- Repo.getRoles candidate
        pure (outcome, roles)
      case result of
        Left err               -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, roles) -> do
          outcome `shouldBe` Right ()
          roles   `shouldBe` [Administrator]

    it "rejects granting a role the target already has" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        admin <- createTestUser "seed-admin2"
        Repo.insertRoleMembership admin Administrator
        grantRole admin admin Administrator
      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldBe` Left RoleAlreadyAssigned

    it "records a RoleGranted audit event on successful grant" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        admin     <- createTestUser "audit-grant-admin"
        candidate <- createTestUser "audit-grant-target"
        Repo.insertRoleMembership admin Administrator
        _ <- unwrap =<< grantRole admin candidate Administrator
        Repo.listAuditEventsForEntity candidate
      case result of
        Left err      -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right [event] -> do
          auditOperation event `shouldBe` RoleGranted Administrator
        Right other   -> expectationFailure ("expected exactly one event, got: " ++ show other)

    it "rejects a grant from a non-admin actor" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        actor  <- createTestUser "non-admin-granter"
        target <- createTestUser "grant-target"
        grantRole actor target Administrator
      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldBe` Left (GR.Unauthorized NotAdministrator)

    it "revokes an existing role when another Administrator remains" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        admin1 <- createTestUser "revoker"
        admin2 <- createTestUser "revocable"
        Repo.insertRoleMembership admin1 Administrator
        Repo.insertRoleMembership admin2 Administrator
        outcome <- revokeRole admin1 admin2 Administrator
        roles   <- Repo.getRoles admin2
        pure (outcome, roles)
      case result of
        Left err               -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, roles) -> do
          outcome `shouldBe` Right ()
          roles   `shouldBe` []

    it "rejects revoking a role the target doesn't have" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        admin  <- createTestUser "seed-admin3"
        target <- createTestUser "unassigned-target"
        Repo.insertRoleMembership admin Administrator
        revokeRole admin target Administrator
      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldBe` Left RoleNotAssigned

    it "records a RoleRevoked audit event on successful revoke" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        admin1 <- createTestUser "audit-revoke-admin1"
        admin2 <- createTestUser "audit-revoke-admin2"
        Repo.insertRoleMembership admin1 Administrator
        Repo.insertRoleMembership admin2 Administrator
        _ <- unwrap =<< revokeRole admin1 admin2 Administrator
        Repo.listAuditEventsForEntity admin2
      case result of
        Left err      -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right [event] -> auditOperation event `shouldBe` RoleRevoked Administrator
        Right other   -> expectationFailure ("expected exactly one event, got: " ++ show other)

    it "rejects a revocation from a non-admin actor" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        actor  <- createTestUser "non-admin-revoker"
        target <- createTestUser "revoke-target"
        Repo.insertRoleMembership target Administrator
        revokeRole actor target Administrator
      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldBe` Left (RR.Unauthorized NotAdministrator)

    it "rejects revoking the last Administrator in the system" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        soleAdmin <- createTestUser "sole-admin"
        Repo.insertRoleMembership soleAdmin Administrator
        revokeRole soleAdmin soleAdmin Administrator
      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldBe` Left CannotRevokeLastAdministrator

  describe "requireAdministrator (pure)" $ do

    it "authorizes a user who has the Administrator role" $
      requireAdministrator [Administrator] `shouldBe` Right ()

    it "rejects a user with no roles" $
      requireAdministrator [] `shouldBe` Left NotAdministrator

  describe "SetAccountStatus authorization (Thread 9)" $ do

    it "rejects a non-admin actor before mutating the target, and leaves status unchanged" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        actor  <- createTestUser "non-admin-actor"
        target <- createTestUser "target-user"
        outcome <- setAccountStatus SetAccountStatusRequest
          { statusActorId = actor
          , statusUserId  = target
          , statusNew     = Suspended
          }
        maybeUser <- Repo.findUserById target
        pure (outcome, maybeUser)
      case result of
        Left err                   -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, maybeUser) -> do
          outcome `shouldBe` Left (SAS.Unauthorized NotAdministrator)
          fmap accountStatus maybeUser `shouldBe` Just Active

    it "rejects an admin actor when the target doesn't exist" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        actor <- createTestUser "admin-actor"
        Repo.insertRoleMembership actor Administrator
        setAccountStatus SetAccountStatusRequest
          { statusActorId = actor
          , statusUserId  = UserId 9999
          , statusNew     = Suspended
          }
      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldBe` Left StatusUserNotFound

    it "allows an admin actor to change an existing target's status" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        actor  <- createTestUser "admin-actor-2"
        target <- createTestUser "target-user-2"
        Repo.insertRoleMembership actor Administrator
        outcome <- setAccountStatus SetAccountStatusRequest
          { statusActorId = actor
          , statusUserId  = target
          , statusNew     = Suspended
          }
        maybeUser <- Repo.findUserById target
        pure (outcome, maybeUser)
      case result of
        Left err                   -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, maybeUser) -> do
          outcome `shouldBe` Right ()
          fmap accountStatus maybeUser `shouldBe` Just Suspended

    it "records an AccountStatusChanged audit event with correct before/after" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        admin  <- createTestUser "audit-status-admin"
        target <- createTestUser "audit-status-target"
        Repo.insertRoleMembership admin Administrator
        _ <- unwrap =<< setAccountStatus SetAccountStatusRequest
          { statusActorId = admin, statusUserId = target, statusNew = Suspended }
        Repo.listAuditEventsForEntity target
      case result of
        Left err      -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right [event] -> auditOperation event `shouldBe` AccountStatusChanged Active Suspended
        Right other   -> expectationFailure ("expected exactly one event, got: " ++ show other)

  describe "Administrator Dashboard (Thread 10)" $ do

    it "rejects a non-admin actor" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        actor <- createTestUser "not-admin"
        getAdministratorDashboard actor
      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldBe` Left (GAD.Unauthorized NotAdministrator)

    it "shows tournaments across every owner, unfiltered" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        admin  <- createTestUser "the-admin"
        owner1 <- createTestUser "owner-one"
        owner2 <- createTestUser "owner-two"
        Repo.insertRoleMembership admin Administrator
        _ <- createTournament NewTournament
          { newTournamentName = TournamentName "Owner1 Cup", newTournamentOrganizer = OrganizerName "x"
          , newTournamentOwner = owner1, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 2 }
        _ <- createTournament NewTournament
          { newTournamentName = TournamentName "Owner2 Cup", newTournamentOrganizer = OrganizerName "x"
          , newTournamentOwner = owner2, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 2 }
        getAdministratorDashboard admin
      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> case inner of
          Left dashErr -> expectationFailure (show dashErr)
          Right dash   -> length (overviewTournaments dash) `shouldBe` 2

  describe "AuditLogRepository adapter" $ do

    it "returns [] for an entity with no audit events" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        target <- createTestUser "no-events-target"
        Repo.listAuditEventsForEntity target
      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right events -> events `shouldBe` []

    it "records and retrieves a RoleGranted event" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        actor  <- createTestUser "audit-actor"
        target <- createTestUser "audit-target"
        now    <- liftIO getCurrentTime
        Repo.recordAuditEvent AuditEvent
          { auditActor = actor, auditEntity = target
          , auditOperation = RoleGranted Administrator, auditTime = now }
        Repo.listAuditEventsForEntity target
      case result of
        Left err      -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right [event] -> do
          auditOperation event `shouldBe` RoleGranted Administrator
        Right other   -> expectationFailure ("expected exactly one event, got: " ++ show other)

    it "records and retrieves an AccountStatusChanged event with before/after" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        actor  <- createTestUser "audit-actor-2"
        target <- createTestUser "audit-target-2"
        now    <- liftIO getCurrentTime
        Repo.recordAuditEvent AuditEvent
          { auditActor = actor, auditEntity = target
          , auditOperation = AccountStatusChanged Active Suspended, auditTime = now }
        Repo.listAuditEventsForEntity target
      case result of
        Left err      -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right [event] -> auditOperation event `shouldBe` AccountStatusChanged Active Suspended
        Right other   -> expectationFailure ("expected exactly one event, got: " ++ show other)

    it "keeps audit events isolated per entity" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        actor   <- createTestUser "audit-actor-3"
        target1 <- createTestUser "audit-target-3a"
        target2 <- createTestUser "audit-target-3b"
        now     <- liftIO getCurrentTime
        Repo.recordAuditEvent AuditEvent
          { auditActor = actor, auditEntity = target1
          , auditOperation = RoleGranted Administrator, auditTime = now }
        events1 <- Repo.listAuditEventsForEntity target1
        events2 <- Repo.listAuditEventsForEntity target2
        pure (events1, events2)
      case result of
        Left err               -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (events1, events2) -> do
          length events1 `shouldBe` 1
          events2        `shouldBe` []

  describe "RecordEFootballResult (Thread 1, score-derived outcomes)" $ do

    it "derives a Winner outcome and persists the score" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "efootball-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "EFootball Win Cup"
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

        let Right scoreA = mkEFootballScore 3
            Right scoreB = mkEFootballScore 1
        updated <- unwrap =<< recordEFootballResult ownerId (matchId m) scoreA scoreB
        stored  <- Repo.getEFootballScore (matchId m)
        pure (matchOutcome updated, stored)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, stored) -> do
          outcome `shouldBe` Just (Winner (Individual (Player (PlayerName "Alice"))))
          stored  `shouldSatisfy` (/= Nothing)

    it "rejects a Draw outcome derived from tied eFootball scores" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "efootball-draw-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "EFootball Draw Cup"
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

        let Right scoreA = mkEFootballScore 2
            Right scoreB = mkEFootballScore 2
        outcome <- recordEFootballResult ownerId (matchId m) scoreA scoreB
        stored  <- Repo.getEFootballScore (matchId m)
        pure (outcome, stored)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, stored) -> do
          outcome `shouldSatisfy` isLeft
          stored  `shouldBe` Nothing

    it "rejects an eFootball result for a match that hasn't started" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "efootball-notstarted-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "EFootball Not Started Cup"
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
        -- Deliberately not started.

        let Right scoreA = mkEFootballScore 1
            Right scoreB = mkEFootballScore 0
        recordEFootballResult ownerId (matchId m) scoreA scoreB

      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldSatisfy` isLeft

    it "does not persist a score when the underlying result recording is unauthorized" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId    <- createTestUser "efootball-owner-2"
        impostorId <- createTestUser "efootball-impostor"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "EFootball Rollback Cup"
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

        let Right scoreA = mkEFootballScore 2
            Right scoreB = mkEFootballScore 0
        outcome <- recordEFootballResult impostorId (matchId m) scoreA scoreB
        stored  <- Repo.getEFootballScore (matchId m)
        pure (outcome, stored)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, stored) -> do
          outcome `shouldSatisfy` isLeft
          stored  `shouldBe` Nothing

  describe "DoubleElimination (v0.7 DoubleElim sub-thread)" $ do

    it "completes via GF1 when the WB champion wins outright (no reset)" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "de-owner-noreset"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            carol = Individual (Player (PlayerName "Carol"))
            dave  = Individual (Player (PlayerName "Dave"))
            participants = [alice, bob, carol, dave]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "DoubleElim No-Reset Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = DoubleElimination
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

        let playWinner p ms = do
              let m = head (filter (\x -> matchCompetitorA x == p || matchCompetitorB x == p) ms)
              _ <- unwrap =<< startMatch ownerId (matchId m)
              _ <- unwrap =<< recordMatchResult ownerId (matchId m) (Winner p)
              pure ()

        wb1 <- Repo.listMatchesForBracket bracketId
        liftIO $ length wb1 `shouldBe` 2
        -- Alice and Carol advance from WB round 1; Bob and Dave drop to LB1.
        playWinner alice wb1
        playWinner carol wb1

        afterWB1 <- Repo.listMatchesForBracket bracketId
        let scheduled1 = filter (\m -> matchStatus m == Scheduled) afterWB1
        liftIO $ length scheduled1 `shouldBe` 2   -- WB final (Alice v Carol) + LB1 (Bob v Dave)
        playWinner alice scheduled1   -- Alice wins the WB final
        playWinner bob scheduled1     -- Bob wins LB1, eliminating Dave

        afterRound2 <- Repo.listMatchesForBracket bracketId
        let scheduled2 = filter (\m -> matchStatus m == Scheduled) afterRound2
        liftIO $ length scheduled2 `shouldBe` 1   -- LB final: Carol (WB final's loser) v Bob
        playWinner bob scheduled2     -- Bob becomes LB champion

        afterLBFinal <- Repo.listMatchesForBracket bracketId
        let scheduled3 = filter (\m -> matchStatus m == Scheduled) afterLBFinal
        liftIO $ length scheduled3 `shouldBe` 1   -- GF1: Alice (WB champ) v Bob (LB champ)
        playWinner alice scheduled3   -- WB champion wins outright -- no reset needed

        allMatches <- Repo.listMatchesForBracket bracketId
        let stillScheduled = filter (\m -> matchStatus m == Scheduled) allMatches
        liftIO $ length stillScheduled `shouldBe` 0   -- reset node must NOT materialize

        _ <- unwrap =<< startTournament ownerId tid
        unwrap =<< completeTournament ownerId tid

      case result of
        Left err         -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right tournament -> tournamentState tournament `shouldBe` Completed

    it "forces a bracket reset when the LB champion wins GF1, then completes via the reset match" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "de-owner-reset"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            carol = Individual (Player (PlayerName "Carol"))
            dave  = Individual (Player (PlayerName "Dave"))
            participants = [alice, bob, carol, dave]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "DoubleElim Reset Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = DoubleElimination
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

        let playWinner p ms = do
              let m = head (filter (\x -> matchCompetitorA x == p || matchCompetitorB x == p) ms)
              _ <- unwrap =<< startMatch ownerId (matchId m)
              _ <- unwrap =<< recordMatchResult ownerId (matchId m) (Winner p)
              pure ()

        wb1 <- Repo.listMatchesForBracket bracketId
        playWinner alice wb1
        playWinner carol wb1

        afterWB1 <- Repo.listMatchesForBracket bracketId
        let scheduled1 = filter (\m -> matchStatus m == Scheduled) afterWB1
        playWinner alice scheduled1
        playWinner bob scheduled1

        afterRound2 <- Repo.listMatchesForBracket bracketId
        let scheduled2 = filter (\m -> matchStatus m == Scheduled) afterRound2
        playWinner bob scheduled2

        afterLBFinal <- Repo.listMatchesForBracket bracketId
        let scheduled3 = filter (\m -> matchStatus m == Scheduled) afterLBFinal
        liftIO $ length scheduled3 `shouldBe` 1   -- GF1: Alice v Bob
        -- Bob, the LB champion, upsets the WB champion -- must force a reset.
        playWinner bob scheduled3

        beforeCompletion <- completeTournament ownerId tid
        liftIO $ beforeCompletion `shouldBe` Left (CT.InvalidCompletion TournamentNotComplete)   -- reset game still pending

        afterGF1 <- Repo.listMatchesForBracket bracketId
        let resetScheduled = filter (\m -> matchStatus m == Scheduled) afterGF1
        liftIO $ length resetScheduled `shouldBe` 1
        liftIO $ [matchCompetitorA (head resetScheduled), matchCompetitorB (head resetScheduled)]
          `shouldMatchList` [alice, bob]

        playWinner bob resetScheduled   -- Bob confirms himself champion

        _ <- unwrap =<< startTournament ownerId tid
        unwrap =<< completeTournament ownerId tid

      case result of
        Left err         -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right tournament -> tournamentState tournament `shouldBe` Completed

    it "handles a 3-participant DoubleElim bracket (WB bye auto-skips LB1, into the LB final and GF1)" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "de-owner-n3"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            carol = Individual (Player (PlayerName "Carol"))
            participants = [alice, bob, carol]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "DoubleElim Bye Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = DoubleElimination
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

        let playWinner p ms = do
              let m = head (filter (\x -> matchCompetitorA x == p || matchCompetitorB x == p) ms)
              _ <- unwrap =<< startMatch ownerId (matchId m)
              _ <- unwrap =<< recordMatchResult ownerId (matchId m) (Winner p)
              pure ()

        wb1 <- Repo.listMatchesForBracket bracketId
        liftIO $ length wb1 `shouldBe` 1   -- Alice's bye means only Bob v Carol is a real WB1 match
        liftIO $ [matchCompetitorA (head wb1), matchCompetitorB (head wb1)]
          `shouldMatchList` [bob, carol]
        playWinner bob wb1

        afterWB1 <- Repo.listMatchesForBracket bracketId
        let scheduled1 = filter (\m -> matchStatus m == Scheduled) afterWB1
        liftIO $ length scheduled1 `shouldBe` 1   -- WB final: Alice v Bob (Carol's loss auto-skips LB1)
        liftIO $ [matchCompetitorA (head scheduled1), matchCompetitorB (head scheduled1)]
          `shouldMatchList` [alice, bob]
        playWinner alice scheduled1

        afterWBFinal <- Repo.listMatchesForBracket bracketId
        let scheduled2 = filter (\m -> matchStatus m == Scheduled) afterWBFinal
        liftIO $ length scheduled2 `shouldBe` 1   -- LB final: Bob (WB final's loser) v Carol
        liftIO $ [matchCompetitorA (head scheduled2), matchCompetitorB (head scheduled2)]
          `shouldMatchList` [bob, carol]
        playWinner carol scheduled2

        afterLBFinal <- Repo.listMatchesForBracket bracketId
        let scheduled3 = filter (\m -> matchStatus m == Scheduled) afterLBFinal
        liftIO $ length scheduled3 `shouldBe` 1   -- GF1: Alice (WB champ) v Carol (LB champ)
        liftIO $ [matchCompetitorA (head scheduled3), matchCompetitorB (head scheduled3)]
          `shouldMatchList` [alice, carol]
        playWinner alice scheduled3   -- WB champion wins outright

        _ <- unwrap =<< startTournament ownerId tid
        unwrap =<< completeTournament ownerId tid

      case result of
        Left err         -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right tournament -> tournamentState tournament `shouldBe` Completed

    it "rejects correction on an in-progress DoubleElim tournament with UnsupportedFormatForCorrection" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "de-corr-format-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            carol = Individual (Player (PlayerName "Carol"))
            dave  = Individual (Player (PlayerName "Dave"))
            participants = [alice, bob, carol, dave]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "DoubleElim Format Rejection Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = DoubleElimination
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

        wb1 <- Repo.listMatchesForBracket bracketId
        let m = head wb1
        _ <- unwrap =<< startMatch ownerId (matchId m)
        _ <- unwrap =<< recordMatchResult ownerId (matchId m) (Winner (matchCompetitorA m))

        matchBefore <- Repo.getMatch (matchId m)
        outcome <- correctMatchResult ownerId (matchId m) (Winner (matchCompetitorB m))
        matchAfter <- Repo.getMatch (matchId m)

        pure (outcome, matchBefore, matchAfter)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, matchBefore, matchAfter) -> do
          outcome `shouldBe` Left (UnsupportedFormatForCorrection DoubleElimination)
          matchOutcome matchAfter `shouldBe` matchOutcome matchBefore

    it "rejects correction on a Completed DoubleElim tournament with TournamentAlreadyCompleted, not the format error" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "de-corr-completed-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            carol = Individual (Player (PlayerName "Carol"))
            dave  = Individual (Player (PlayerName "Dave"))
            participants = [alice, bob, carol, dave]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "DoubleElim Completed Correction Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = DoubleElimination
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

        let playWinner p ms = do
              let m = head (filter (\x -> matchCompetitorA x == p || matchCompetitorB x == p) ms)
              _ <- unwrap =<< startMatch ownerId (matchId m)
              _ <- unwrap =<< recordMatchResult ownerId (matchId m) (Winner p)
              pure ()

        wb1 <- Repo.listMatchesForBracket bracketId
        playWinner alice wb1
        playWinner carol wb1

        afterWB1 <- Repo.listMatchesForBracket bracketId
        let scheduled1 = filter (\m -> matchStatus m == Scheduled) afterWB1
        playWinner alice scheduled1
        playWinner bob scheduled1

        afterRound2 <- Repo.listMatchesForBracket bracketId
        let scheduled2 = filter (\m -> matchStatus m == Scheduled) afterRound2
        playWinner bob scheduled2

        afterLBFinal <- Repo.listMatchesForBracket bracketId
        let scheduled3 = filter (\m -> matchStatus m == Scheduled) afterLBFinal
            gf1Match = head scheduled3
        playWinner alice scheduled3   -- WB champion wins outright -- no reset needed

        _ <- unwrap =<< startTournament ownerId tid
        _ <- unwrap =<< completeTournament ownerId tid

        tournamentBefore <- Repo.getTournament tid
        matchBefore       <- Repo.getMatch (matchId gf1Match)

        outcome <- correctMatchResult ownerId (matchId gf1Match) (Winner bob)

        tournamentAfter <- Repo.getTournament tid
        matchAfter       <- Repo.getMatch (matchId gf1Match)

        pure (outcome, tournamentBefore, tournamentAfter, matchBefore, matchAfter)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, tournamentBefore, tournamentAfter, matchBefore, matchAfter) -> do
          outcome `shouldBe` Left Application.UseCases.CorrectMatchResult.TournamentAlreadyCompleted
          tournamentState tournamentAfter `shouldBe` tournamentState tournamentBefore
          matchOutcome matchAfter `shouldBe` matchOutcome matchBefore

   

  describe "buildLosersTopology bye-awareness (Engine.BracketGeneration, pure)" $ do

    it "gives LB1 an explicit bye slot when one WB1 sibling is a bye (n=3 into size 4)" $ do
      let participants =
            [ Individual (Player (PlayerName "P1"))
            , Individual (Player (PlayerName "P2"))
            , Individual (Player (PlayerName "P3"))
            ]
          wbNodes  = BracketGeneration.buildTopology 4
          seededWB = Seeding.seedParticipants participants wbNodes
          lbNodes  = BracketGeneration.buildLosersTopology seededWB 4

      map nodeId lbNodes `shouldBe` [BracketNodeId 4, BracketNodeId 5]

      let lb1 = lbNodes !! 0
      nodeSlotA lb1 `shouldBe` AwaitingLoserOf (BracketNodeId 2)
      nodeSlotB lb1 `shouldBe` ByeSlot
      nodeRound lb1 `shouldBe` 1
      nodeStage lb1 `shouldBe` Losers

      let lbFinal = lbNodes !! 1
      nodeSlotA lbFinal `shouldBe` AwaitingLoserOf (BracketNodeId 3)
      nodeSlotB lbFinal `shouldBe` AwaitingWinnerOf (BracketNodeId 4)
      nodeRound lbFinal `shouldBe` 2

    it "gives an orphaned WB round-2 drop-in an explicit bye when its sibling family was fully byed (n=5 into size 8)" $ do
      let participants =
            [ Individual (Player (PlayerName "P1"))
            , Individual (Player (PlayerName "P2"))
            , Individual (Player (PlayerName "P3"))
            , Individual (Player (PlayerName "P4"))
            , Individual (Player (PlayerName "P5"))
            ]
          wbNodes  = BracketGeneration.buildTopology 8
          seededWB = Seeding.seedParticipants participants wbNodes
          lbNodes  = BracketGeneration.buildLosersTopology seededWB 8

      map nodeId lbNodes `shouldBe` map BracketNodeId [8, 9, 10, 11, 12]

      let [lb1, lb2a, lb2b, lb3, lbFinal] = lbNodes

      -- LB1: pair (1,2) both byes -> no node for it. pair (3,4) one bye -> single node.
      nodeSlotA lb1 `shouldBe` AwaitingLoserOf (BracketNodeId 4)
      nodeSlotB lb1 `shouldBe` ByeSlot

      -- LB2: node 5's loser has a real cross-seed partner (LB1's survivor).
      nodeSlotA lb2a `shouldBe` AwaitingLoserOf (BracketNodeId 5)
      nodeSlotB lb2a `shouldBe` AwaitingWinnerOf (BracketNodeId 8)

      -- LB2: node 6's loser is the orphan -- its tagged sibling (node 5's family)
      -- produced no LB1 survivor, so it gets an explicit bye instead of vanishing.
      nodeSlotA lb2b `shouldBe` AwaitingLoserOf (BracketNodeId 6)
      nodeSlotB lb2b `shouldBe` ByeSlot

      -- LB3 (pure merge): both LB2 survivors share a tag, so they meet.
      nodeSlotA lb3 `shouldBe` AwaitingWinnerOf (BracketNodeId 9)
      nodeSlotB lb3 `shouldBe` AwaitingWinnerOf (BracketNodeId 10)

      -- LB4 (LB final): WB final's loser drops in against the LB3 survivor.
      nodeSlotA lbFinal `shouldBe` AwaitingLoserOf (BracketNodeId 7)
      nodeSlotB lbFinal `shouldBe` AwaitingWinnerOf (BracketNodeId 11)

  describe "buildRoundRobinTopology (Engine.BracketGeneration, pure)" $ do

    it "generates n(n-1)/2 unique pairs for n=3, every node born ready" $ do
      let p1 = Individual (Player (PlayerName "P1"))
          p2 = Individual (Player (PlayerName "P2"))
          p3 = Individual (Player (PlayerName "P3"))
          nodes = BracketGeneration.buildRoundRobinTopology [p1, p2, p3]

      map nodeId nodes `shouldBe` map BracketNodeId [1, 2, 3]
      map (\n -> (nodeSlotA n, nodeSlotB n)) nodes `shouldBe`
        [ (Filled p1, Filled p2)
        , (Filled p1, Filled p3)
        , (Filled p2, Filled p3)
        ]
      all (\n -> nodeRound n == 1 && nodeStage n == Winners) nodes `shouldBe` True

    it "generates n(n-1)/2 unique pairs for n=4" $ do
      let p1 = Individual (Player (PlayerName "P1"))
          p2 = Individual (Player (PlayerName "P2"))
          p3 = Individual (Player (PlayerName "P3"))
          p4 = Individual (Player (PlayerName "P4"))
          nodes = BracketGeneration.buildRoundRobinTopology [p1, p2, p3, p4]

      map nodeId nodes `shouldBe` map BracketNodeId [1 .. 6]
      map (\n -> (nodeSlotA n, nodeSlotB n)) nodes `shouldBe`
        [ (Filled p1, Filled p2)
        , (Filled p1, Filled p3)
        , (Filled p1, Filled p4)
        , (Filled p2, Filled p3)
        , (Filled p2, Filled p4)
        , (Filled p3, Filled p4)
        ]

  describe "RoundRobin (v0.8 RoundRobin sub-thread)" $ do

    it "generates every pair as an immediately-playable match, and accepts a Draw as a terminal outcome" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "rr-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            carol = Individual (Player (PlayerName "Carol"))
            participants = [alice, bob, carol]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "RoundRobin Draw Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = RoundRobin
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

        allMatches <- Repo.listMatchesForBracket bracketId
        liftIO $ length allMatches `shouldBe` 3   -- n(n-1)/2 for n=3
        liftIO $ all (\m -> matchStatus m == Scheduled) allMatches `shouldBe` True

        let findMatch p q = head (filter (\m -> [matchCompetitorA m, matchCompetitorB m] `elem` [[p,q],[q,p]]) allMatches)
            aliceBob   = findMatch alice bob
            aliceCarol = findMatch alice carol
            bobCarol   = findMatch bob carol

        -- Exercises the new format-aware gate directly: Draw is rejected
        -- for Single/DoubleElimination but must be accepted for RoundRobin.
        _ <- unwrap =<< startMatch ownerId (matchId aliceBob)
        drawResult <- recordMatchResult ownerId (matchId aliceBob) Draw

        _ <- unwrap =<< startMatch ownerId (matchId aliceCarol)
        _ <- unwrap =<< recordMatchResult ownerId (matchId aliceCarol) (Winner alice)

        _ <- unwrap =<< startMatch ownerId (matchId bobCarol)
        _ <- unwrap =<< recordMatchResult ownerId (matchId bobCarol) (Winner bob)

        finalMatches <- Repo.listMatchesForBracket bracketId
        pure (drawResult, finalMatches)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (drawResult, finalMatches) -> do
          case drawResult of
            Left e  -> expectationFailure ("expected Draw to be accepted for RoundRobin, got: " ++ show e)
            Right m -> do
              matchStatus m `shouldBe` Match.Completed
              matchOutcome m `shouldBe` Just Draw
          length finalMatches `shouldBe` 3
          all (\m -> matchStatus m == Match.Completed) finalMatches `shouldBe` True

    it "completes once every match is terminal, even when the arbitrary last-generated match is the Draw" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "rr-owner-complete"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            carol = Individual (Player (PlayerName "Carol"))
            participants = [alice, bob, carol]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "RoundRobin Completion Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = RoundRobin
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

        allMatches <- Repo.listMatchesForBracket bracketId
        let findMatch p q = head (filter (\m -> [matchCompetitorA m, matchCompetitorB m] `elem` [[p,q],[q,p]]) allMatches)
            aliceBob   = findMatch alice bob
            aliceCarol = findMatch alice carol
            bobCarol   = findMatch bob carol

        -- Before anything is played: must not be completable.
        tooEarly <- completeTournament ownerId tid

        _ <- unwrap =<< startMatch ownerId (matchId aliceBob)
        _ <- unwrap =<< recordMatchResult ownerId (matchId aliceBob) (Winner alice)
        _ <- unwrap =<< startMatch ownerId (matchId aliceCarol)
        _ <- unwrap =<< recordMatchResult ownerId (matchId aliceCarol) (Winner alice)

        -- Two of three done: still not completable.
        stillEarly <- completeTournament ownerId tid

        -- The last-generated match (Bob v Carol) is the Draw -- this is the
        -- exact case the old GF1/reset-presence dispatch got wrong, since it
        -- silently checked only this one arbitrary match via maximumBy.
        _ <- unwrap =<< startMatch ownerId (matchId bobCarol)
        _ <- unwrap =<< recordMatchResult ownerId (matchId bobCarol) Draw

        _ <- unwrap =<< startTournament ownerId tid
        afterAll <- completeTournament ownerId tid

        pure (tooEarly, stillEarly, afterAll)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (tooEarly, stillEarly, afterAll) -> do
          tooEarly   `shouldBe` Left (CT.InvalidCompletion TournamentNotComplete)
          stillEarly `shouldBe` Left (CT.InvalidCompletion TournamentNotComplete)
          case afterAll of
            Left e  -> expectationFailure ("expected completion to succeed once all 3 matches (incl. the Draw) are terminal, got: " ++ show e)
            Right t -> tournamentState t `shouldBe` Completed

    it "rejects correction on an in-progress RoundRobin tournament with UnsupportedFormatForCorrection" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "rr-corr-format-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            carol = Individual (Player (PlayerName "Carol"))
            participants = [alice, bob, carol]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "RoundRobin Format Rejection Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = RoundRobin
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

        allMatches <- Repo.listMatchesForBracket bracketId
        let m = head allMatches
        _ <- unwrap =<< startMatch ownerId (matchId m)
        _ <- unwrap =<< recordMatchResult ownerId (matchId m) (Winner (matchCompetitorA m))

        matchBefore <- Repo.getMatch (matchId m)
        outcome <- correctMatchResult ownerId (matchId m) (Winner (matchCompetitorB m))
        matchAfter <- Repo.getMatch (matchId m)

        pure (outcome, matchBefore, matchAfter)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, matchBefore, matchAfter) -> do
          outcome `shouldBe` Left (UnsupportedFormatForCorrection RoundRobin)
          matchOutcome matchAfter `shouldBe` matchOutcome matchBefore

  describe "Engine.Standings.computeStandings (pure)" $ do

    it "breaks two separate 2-way ties via mini-league head-to-head (n=4)" $ do
      let a = Individual (Player (PlayerName "A"))
          b = Individual (Player (PlayerName "B"))
          c = Individual (Player (PlayerName "C"))
          d = Individual (Player (PlayerName "D"))
          mkMatch i cA cB outcome = Match
            { matchId = MatchId i, matchTournament = TournamentId 0
            , matchBracket = BracketId 0, matchBracketNode = BracketNodeId (fromIntegral i)
            , matchCompetitorA = cA, matchCompetitorB = cB
            , matchStatus = Match.Completed, matchOutcome = Just outcome
            }
          matches =
            [ mkMatch 1 a b (Winner a), mkMatch 2 a c (Winner a), mkMatch 3 a d (Winner d)
            , mkMatch 4 b c (Winner b), mkMatch 5 b d (Winner b), mkMatch 6 c d (Winner c)
            ]
          standings = Standings.computeStandings matches
      map standingParticipant standings `shouldBe` [a, b, c, d]
      map standingPoints standings `shouldBe` [6, 6, 3, 3]

    it "leaves a perfect 3-way cycle unresolved, stable arbitrary order" $ do
      let a = Individual (Player (PlayerName "A"))
          b = Individual (Player (PlayerName "B"))
          c = Individual (Player (PlayerName "C"))
          mkMatch i cA cB outcome = Match
            { matchId = MatchId i, matchTournament = TournamentId 0
            , matchBracket = BracketId 0, matchBracketNode = BracketNodeId (fromIntegral i)
            , matchCompetitorA = cA, matchCompetitorB = cB
            , matchStatus = Match.Completed, matchOutcome = Just outcome
            }
          matches = [ mkMatch 1 a b (Winner a), mkMatch 2 b c (Winner b), mkMatch 3 c a (Winner c) ]
          standings = Standings.computeStandings matches
      map standingParticipant standings `shouldBe` [a, b, c]
      map standingPoints standings `shouldBe` [3, 3, 3]

  describe "GetRoundRobinStandings" $ do

    it "rejects a non-RoundRobin tournament" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "grs-owner-notrr"
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "Not RoundRobin Cup", newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 2 }
        getRoundRobinStandings ownerId tid
      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldBe` Left (NotRoundRobin SingleElimination)

    it "rejects when the bracket hasn't been generated yet" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "grs-owner-nobracket"
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "No Bracket RR Cup", newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = RoundRobin
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 3 }
        getRoundRobinStandings ownerId tid
      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldBe` Left GetRoundRobinStandings.BracketNotGenerated

    it "rejects a non-owner viewing a Private tournament's standings" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId    <- createTestUser "grs-owner-private"
        strangerId <- createTestUser "grs-stranger"
        let participants@[alice,bob,carol] =
              [ Individual (Player (PlayerName "Alice")), Individual (Player (PlayerName "Bob")), Individual (Player (PlayerName "Carol")) ]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "Private RR Cup", newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = RoundRobin
          , newTournamentVisibility = Private, newTournamentMaxParticipants = 3 }
        forM_ participants $ \p -> case p of Individual player -> Repo.savePlayer player; Squad team -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        _ <- unwrap =<< generateBracket ownerId tid
        getRoundRobinStandings strangerId tid
      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldBe` Left (GRRS.Unauthorized NotAuthorizedToView)

    it "allows the owner to view a Private tournament's standings" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "grs-owner-private2"
        let participants@[alice,bob,carol] =
              [ Individual (Player (PlayerName "Alice")), Individual (Player (PlayerName "Bob")), Individual (Player (PlayerName "Carol")) ]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "Private RR Owner Cup", newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = RoundRobin
          , newTournamentVisibility = Private, newTournamentMaxParticipants = 3 }
        forM_ participants $ \p -> case p of Individual player -> Repo.savePlayer player; Squad team -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        _ <- unwrap =<< generateBracket ownerId tid
        getRoundRobinStandings ownerId tid
      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> case inner of
          Left e  -> expectationFailure ("expected owner to view standings, got: " ++ show e)
          Right _ -> pure ()

    it "allows any authenticated caller to view a Public tournament's standings, with correct points" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId    <- createTestUser "grs-owner-public"
        strangerId <- createTestUser "grs-stranger2"
        let participants@[alice,bob,carol] =
              [ Individual (Player (PlayerName "Alice")), Individual (Player (PlayerName "Bob")), Individual (Player (PlayerName "Carol")) ]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "Public RR Cup", newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = RoundRobin
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 3 }
        forM_ participants $ \p -> case p of Individual player -> Repo.savePlayer player; Squad team -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        allMatches <- Repo.listMatchesForBracket bracketId
        let findMatch p q = head (filter (\m -> [matchCompetitorA m, matchCompetitorB m] `elem` [[p,q],[q,p]]) allMatches)
            aliceBob = findMatch alice bob; aliceCarol = findMatch alice carol; bobCarol = findMatch bob carol
        _ <- unwrap =<< startMatch ownerId (matchId aliceBob)
        _ <- unwrap =<< recordMatchResult ownerId (matchId aliceBob) (Winner alice)
        _ <- unwrap =<< startMatch ownerId (matchId aliceCarol)
        _ <- unwrap =<< recordMatchResult ownerId (matchId aliceCarol) (Winner alice)
        _ <- unwrap =<< startMatch ownerId (matchId bobCarol)
        _ <- unwrap =<< recordMatchResult ownerId (matchId bobCarol) Draw
        getRoundRobinStandings strangerId tid
      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> case inner of
          Left e -> expectationFailure ("expected stranger to view Public standings, got: " ++ show e)
          Right standings -> do
            -- Alice beat both (3+3=6). Bob/Carol drew each other, both lost to
            -- Alice (0+1=1 each) -- tied at 1, mini-league is just their own
            -- drawn match (1-1 again), stays unresolved -- stable order asserted.
            let alice = Individual (Player (PlayerName "Alice"))
                bob   = Individual (Player (PlayerName "Bob"))
                carol = Individual (Player (PlayerName "Carol"))
                dave  = Individual (Player (PlayerName "Dave"))
                participants = [alice, bob, carol, dave]

            map standingPoints standings `shouldBe` [6, 1, 1]
            head standings `shouldBe` Standing alice 6


  describe "withTxEither" $ do

    it "rolls back all writes when the block returns Left" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "txeither-owner-rollback"
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Original"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }

        inner <- withTxEither $ do
          tournament <- Repo.getTournament tid
          Repo.saveTournament tournament { tournamentName = TournamentName "Should Not Persist" }
          pure (Left TestTxError :: Either TestTxError ())

        reread <- Repo.getTournament tid
        pure (inner, reread)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (inner, reread) -> do
          inner `shouldBe` Left TestTxError
          tournamentName reread `shouldBe` TournamentName "Original"

    it "commits all writes when the block returns Right" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "txeither-owner-commit"
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Original"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }

        inner <- withTxEither $ do
          tournament <- Repo.getTournament tid
          Repo.saveTournament tournament { tournamentName = TournamentName "Renamed" }
          pure (Right () :: Either TestTxError ())

        reread <- Repo.getTournament tid
        pure (inner, reread)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (inner, reread) -> do
          inner `shouldBe` Right ()
          tournamentName reread `shouldBe` TournamentName "Renamed"

  describe "Materialization structural invariant (protects v0.8.2 correction shortcut)" $ do

    it "singleElim_doesNotMaterializeDownstreamMatchUntilPredecessorCompletes" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "matinv-owner"
        let participants =
              [ Individual (Player (PlayerName ("P" ++ show i))) | i <- [1 .. 8 :: Int] ]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Materialization Invariant Cup"
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
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid

        r1 <- Repo.listMatchesForBracket bracketId
        liftIO $ length r1 `shouldBe` 4

        let playMatch m = do
              _ <- unwrap =<< startMatch ownerId (matchId m)
              unwrap =<< recordMatchResult ownerId (matchId m) (Winner (matchCompetitorA m))

        -- Complete all four round-1 matches -- materializes both round-2
        -- matches (M5, M6), but the round-3 final (M7) must still be
        -- absent, since neither round-2 match has been played yet.
        _ <- playMatch (r1 !! 0)
        _ <- playMatch (r1 !! 1)
        _ <- playMatch (r1 !! 2)
        _ <- playMatch (r1 !! 3)

        afterAllR1 <- Repo.listMatchesForBracket bracketId
        liftIO $ length afterAllR1 `shouldBe` 6   -- 4 R1 + M5 + M6; M7 absent

        let round2Matches = filter (\m -> matchStatus m == Scheduled) afterAllR1
        liftIO $ length round2Matches `shouldBe` 2

        -- Complete ONLY the first round-2 match. Its sibling remains
        -- merely Scheduled, not Completed.
        _ <- playMatch (head round2Matches)

        -- KEY ASSERTION: one round-2 match completing must NOT materialize
        -- the final while its sibling is still Scheduled.
        afterOneR2 <- Repo.listMatchesForBracket bracketId
        let countAfterOneR2 = length afterOneR2

        -- Now complete the sibling round-2 match too -- both of the
        -- final's predecessors are now Completed.
        _ <- playMatch (round2Matches !! 1)

        afterBothR2 <- Repo.listMatchesForBracket bracketId
        pure (countAfterOneR2, length afterBothR2)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (countAfterOneR2, countAfterBothR2) -> do
          countAfterOneR2  `shouldBe` 6   -- final NOT materialized: sibling still Scheduled
          countAfterBothR2 `shouldBe` 7   -- final materialized: both predecessors Completed


  describe "CorrectMatchResult (v0.8.2, Single Elim)" $ do

    it "Case A: succeeds with no downstream Match row to reconcile" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "corr-a-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            carol = Individual (Player (PlayerName "Carol"))
            dave  = Individual (Player (PlayerName "Dave"))
            participants = [alice, bob, carol, dave]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "Correction Case A Cup"
          , newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 4 }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid

        r1 <- Repo.listMatchesForBracket bracketId
        let m1 = head r1   -- deliberately leave the OTHER r1 match unplayed
        _ <- unwrap =<< startMatch ownerId (matchId m1)
        _ <- unwrap =<< recordMatchResult ownerId (matchId m1) (Winner (matchCompetitorA m1))

        -- No round-2 node can have materialized: its other prerequisite
        -- (the sibling r1 match) hasn't completed.
        afterFirst <- Repo.listMatchesForBracket bracketId
        liftIO $ length afterFirst `shouldBe` 2   -- only the 2 r1 matches exist

        let otherWinner = if matchCompetitorA m1 == alice then bob else alice
        corrected <- unwrap =<< correctMatchResult ownerId (matchId m1) (Winner otherWinner)
        pure corrected

      case result of
        Left err        -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right corrected -> matchOutcome corrected `shouldSatisfy` isJust

    it "Case B: succeeds and replaces the propagated participant in the Scheduled downstream match" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "corr-b-owner"
        let participants =
              [ Individual (Player (PlayerName ("P" ++ show i))) | i <- [1 .. 5 :: Int] ]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "Correction Case B Cup"
          , newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 5 }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid

        (_, nodesBefore) <- Repo.getBracket bracketId
        let round1NodeIds = map nodeId (filter ((== 1) . nodeRound) nodesBefore)
        allMatchesAtGen <- Repo.listMatchesForBracket bracketId
        -- The real round-1 match: identified by its NODE's round, not by
        -- list position -- distinguishes it from any bye-cascade match
        -- that may have already materialized at generation time.
        let m1 = head (filter (\m -> matchBracketNode m `elem` round1NodeIds) allMatchesAtGen)
            m1Winner = matchCompetitorA m1
            m1Loser  = matchCompetitorB m1

            -- True downstream node id, found via the same AwaitingWinnerOf
            -- relationship findParent uses -- captured from the PRE-PLAY
            -- snapshot, since this pointer is destroyed once filled.
            downstreamNodeId =
              case find (\n -> nodeSlotA n == AwaitingWinnerOf (matchBracketNode m1)
                             || nodeSlotB n == AwaitingWinnerOf (matchBracketNode m1)) nodesBefore of
                Just n  -> nodeId n
                Nothing -> error "test setup invariant violated: m1 has no parent node"

        _ <- unwrap =<< startMatch ownerId (matchId m1)
        _ <- unwrap =<< recordMatchResult ownerId (matchId m1) (Winner m1Winner)

        afterM1 <- Repo.listMatchesForBracket bracketId
        let downstream = head (filter (\m -> matchBracketNode m == downstreamNodeId) afterM1)
        liftIO $ (matchCompetitorA downstream == m1Winner || matchCompetitorB downstream == m1Winner)
          `shouldBe` True

        corrected <- unwrap =<< correctMatchResult ownerId (matchId m1) (Winner m1Loser)

        afterCorrection <- Repo.getMatch (matchId downstream)
        pure (corrected, afterCorrection, m1Winner, m1Loser)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (corrected, afterCorrection, m1Winner, m1Loser) -> do
          matchOutcome corrected `shouldBe` Just (Winner m1Loser)
          (matchCompetitorA afterCorrection == m1Winner || matchCompetitorB afterCorrection == m1Winner)
            `shouldBe` False
          (matchCompetitorA afterCorrection == m1Loser || matchCompetitorB afterCorrection == m1Loser)
            `shouldBe` True
    it "Case C: rejects with DownstreamMatchStarted when the downstream match is InProgress" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "corr-c-owner"
        let participants =
              [ Individual (Player (PlayerName ("P" ++ show i))) | i <- [1 .. 4 :: Int] ]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "Correction Case C Cup"
          , newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 4 }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid

        r1 <- Repo.listMatchesForBracket bracketId
        let [ma, mb] = r1
        _ <- unwrap =<< startMatch ownerId (matchId ma)
        _ <- unwrap =<< recordMatchResult ownerId (matchId ma) (Winner (matchCompetitorA ma))
        _ <- unwrap =<< startMatch ownerId (matchId mb)
        _ <- unwrap =<< recordMatchResult ownerId (matchId mb) (Winner (matchCompetitorA mb))

        afterR1 <- Repo.listMatchesForBracket bracketId
        let final = head (filter (\m -> matchStatus m == Scheduled) afterR1)
        _ <- unwrap =<< startMatch ownerId (matchId final)   -- InProgress, not yet completed

        beforeState <- Repo.getMatch (matchId ma)
        outcome <- correctMatchResult ownerId (matchId ma) (Winner (matchCompetitorB ma))
        afterState <- Repo.getMatch (matchId ma)
        pure (outcome, beforeState, afterState, matchId final)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, beforeState, afterState, finalId) -> do
          outcome `shouldBe` Left (DownstreamMatchStarted finalId)
          matchOutcome afterState `shouldBe` matchOutcome beforeState   -- zero mutation

    it "Case D: rejects with DownstreamMatchStarted when the downstream match is Completed" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "corr-d-owner"
        let participants =
              [ Individual (Player (PlayerName ("P" ++ show i))) | i <- [1 .. 4 :: Int] ]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "Correction Case D Cup"
          , newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 4 }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid

        r1 <- Repo.listMatchesForBracket bracketId
        let [ma, mb] = r1
        _ <- unwrap =<< startMatch ownerId (matchId ma)
        _ <- unwrap =<< recordMatchResult ownerId (matchId ma) (Winner (matchCompetitorA ma))
        _ <- unwrap =<< startMatch ownerId (matchId mb)
        _ <- unwrap =<< recordMatchResult ownerId (matchId mb) (Winner (matchCompetitorA mb))

        afterR1 <- Repo.listMatchesForBracket bracketId
        let final = head (filter (\m -> matchStatus m == Scheduled) afterR1)
        _ <- unwrap =<< startMatch ownerId (matchId final)
        _ <- unwrap =<< recordMatchResult ownerId (matchId final) (Winner (matchCompetitorA final))

        beforeState <- Repo.getMatch (matchId ma)
        outcome <- correctMatchResult ownerId (matchId ma) (Winner (matchCompetitorB ma))
        afterState <- Repo.getMatch (matchId ma)
        pure (outcome, beforeState, afterState, matchId final)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, beforeState, afterState, finalId) -> do
          outcome `shouldBe` Left (DownstreamMatchStarted finalId)
          matchOutcome afterState `shouldBe` matchOutcome beforeState

    it "chained correction: A -> B -> A returns to the original propagated state" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "corr-chain-owner"
        let participants =
              [ Individual (Player (PlayerName ("P" ++ show i))) | i <- [1 .. 5 :: Int] ]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "Correction Chain Cup"
          , newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 5 }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid

        (_, nodesBefore) <- Repo.getBracket bracketId
        let round1NodeIds = map nodeId (filter ((== 1) . nodeRound) nodesBefore)
        allMatchesAtGen <- Repo.listMatchesForBracket bracketId
        let m1 = head (filter (\m -> matchBracketNode m `elem` round1NodeIds) allMatchesAtGen)
            original   = matchCompetitorA m1
            challenger = matchCompetitorB m1
            downstreamNodeId =
              case find (\n -> nodeSlotA n == AwaitingWinnerOf (matchBracketNode m1)
                             || nodeSlotB n == AwaitingWinnerOf (matchBracketNode m1)) nodesBefore of
                Just n  -> nodeId n
                Nothing -> error "test setup invariant violated: m1 has no parent node"

        _ <- unwrap =<< startMatch ownerId (matchId m1)
        _ <- unwrap =<< recordMatchResult ownerId (matchId m1) (Winner original)

        afterM1 <- Repo.listMatchesForBracket bracketId
        let downstream = head (filter (\m -> matchBracketNode m == downstreamNodeId) afterM1)
        downstreamBefore <- Repo.getMatch (matchId downstream)

        _ <- unwrap =<< correctMatchResult ownerId (matchId m1) (Winner challenger)
        _ <- unwrap =<< correctMatchResult ownerId (matchId m1) (Winner original)

        m1Final <- Repo.getMatch (matchId m1)
        downstreamAfter <- Repo.getMatch (matchId downstream)
        pure (m1Final, downstreamBefore, downstreamAfter)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (m1Final, downstreamBefore, downstreamAfter) -> do
          matchCompetitorA downstreamAfter `shouldBe` matchCompetitorA downstreamBefore
          matchCompetitorB downstreamAfter `shouldBe` matchCompetitorB downstreamBefore

    it "defensive: rejects Completed source with invalid persisted outcome" $ do
      -- Deliberately bypass the use-case layer to manufacture an
      -- impossible persisted state and verify the integrity backstop.
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "corr-defensive-source-owner"
        let participants =
              [ Individual (Player (PlayerName ("P" ++ show i))) | i <- [1 .. 4 :: Int] ]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Defensive Source Outcome Cup"
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

        r1 <- Repo.listMatchesForBracket bracketId
        let m1 = head r1
        _ <- unwrap =<< startMatch ownerId (matchId m1)
        _ <- unwrap =<< recordMatchResult ownerId (matchId m1) (Winner (matchCompetitorA m1))

        -- Legitimate result recorded via the normal pipeline above, then
        -- OVERWRITTEN directly via the repository -- RecordMatchResult
        -- would never itself produce this outcome for SingleElimination
        -- (Draw/NoContest are rejected outright), so this state is only
        -- reachable by bypassing the use-case layer entirely.
        legitMatch <- Repo.getMatch (matchId m1)
        let corrupted = legitMatch { matchOutcome = Just Draw }
        Repo.saveMatch corrupted

        matchBefore <- Repo.getMatch (matchId m1)
        outcome <- correctMatchResult ownerId (matchId m1) (Winner (matchCompetitorB m1))
        matchAfter <- Repo.getMatch (matchId m1)

        pure (outcome, matchBefore, matchAfter)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, matchBefore, matchAfter) -> do
          outcome `shouldBe` Left (SourceMatchOutcomeInvalid (matchId matchBefore))
          matchOutcome matchAfter `shouldBe` matchOutcome matchBefore

    it "defensive: rejects downstream participant contradiction" $ do
      -- Deliberately bypass the use-case layer to manufacture an
      -- impossible persisted state and verify the integrity backstop.
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "corr-defensive-integrity-owner"
        let participants =
              [ Individual (Player (PlayerName ("P" ++ show i))) | i <- [1 .. 5 :: Int] ]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Defensive Integrity Violation Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 5
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid

        (_, nodesBefore) <- Repo.getBracket bracketId
        let round1NodeIds = map nodeId (filter ((== 1) . nodeRound) nodesBefore)
        allMatchesAtGen <- Repo.listMatchesForBracket bracketId
        let m1 = head (filter (\m -> matchBracketNode m `elem` round1NodeIds) allMatchesAtGen)
            m1Winner = matchCompetitorA m1
            m1Loser  = matchCompetitorB m1
            downstreamNodeId =
              case find (\n -> nodeSlotA n == AwaitingWinnerOf (matchBracketNode m1)
                             || nodeSlotB n == AwaitingWinnerOf (matchBracketNode m1)) nodesBefore of
                Just n  -> nodeId n
                Nothing -> error "test setup invariant violated: m1 has no parent node"

        _ <- unwrap =<< startMatch ownerId (matchId m1)
        _ <- unwrap =<< recordMatchResult ownerId (matchId m1) (Winner m1Winner)

        afterM1 <- Repo.listMatchesForBracket bracketId
        let downstream = head (filter (\m -> matchBracketNode m == downstreamNodeId) afterM1)

        let outsider = Individual (Player (PlayerName "Outsider"))
        Repo.savePlayer (Player (PlayerName "Outsider"))
        _ <- Repo.resolveParticipant outsider
        let corrupted = downstream { matchCompetitorA = m1Loser, matchCompetitorB = outsider }
        Repo.saveMatch corrupted

        matchBeforeSource     <- Repo.getMatch (matchId m1)
        matchBeforeDownstream <- Repo.getMatch (matchId downstream)

        outcome <- correctMatchResult ownerId (matchId m1) (Winner m1Loser)

        matchAfterSource     <- Repo.getMatch (matchId m1)
        matchAfterDownstream <- Repo.getMatch (matchId downstream)

        pure (outcome, matchBeforeSource, matchAfterSource, matchBeforeDownstream, matchAfterDownstream, downstream)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, beforeSource, afterSource, beforeDownstream, afterDownstream, downstream) -> do
          outcome `shouldBe` Left (CorrectionIntegrityViolation (matchId downstream))
          matchOutcome afterSource `shouldBe` matchOutcome beforeSource
          matchCompetitorA afterDownstream `shouldBe` matchCompetitorA beforeDownstream
          matchCompetitorB afterDownstream `shouldBe` matchCompetitorB beforeDownstream

    it "sibling branch does not block correction of an unrelated match" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "corr-sibling-owner"
        let participants =
              [ Individual (Player (PlayerName ("P" ++ show i))) | i <- [1 .. 8 :: Int] ]

        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "Correction Sibling Branch Cup"
          , newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId
          , newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public
          , newTournamentMaxParticipants = 8 }

        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team

        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid

        r1 <- Repo.listMatchesForBracket bracketId
        liftIO $ length r1 `shouldBe` 4
        let m1 = r1 !! 0
            m2 = r1 !! 1
            original    = matchCompetitorA m1
            replacement = matchCompetitorB m1

        _ <- unwrap =<< startMatch ownerId (matchId m1)
        _ <- unwrap =<< recordMatchResult ownerId (matchId m1) (Winner original)

        _ <- unwrap =<< startMatch ownerId (matchId m2)
        siblingBefore <- Repo.getMatch (matchId m2)

        correction <- correctMatchResult ownerId (matchId m1) (Winner replacement)

        siblingAfter <- Repo.getMatch (matchId m2)
        correctedM1 <- Repo.getMatch (matchId m1)

        pure (correction, siblingBefore, siblingAfter, correctedM1, replacement)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (correction, siblingBefore, siblingAfter, correctedM1, replacement) -> do
          correction `shouldSatisfy` isRight
          matchStatus siblingAfter `shouldBe` matchStatus siblingBefore
          matchCompetitorA siblingAfter `shouldBe` matchCompetitorA siblingBefore
          matchCompetitorB siblingAfter `shouldBe` matchCompetitorB siblingBefore
          matchOutcome siblingAfter `shouldBe` matchOutcome siblingBefore
          matchBracketNode siblingAfter `shouldBe` matchBracketNode siblingBefore
          matchId siblingAfter `shouldBe` matchId siblingBefore
          matchOutcome correctedM1 `shouldBe` Just (Winner replacement)