{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Test.Hspec
import Control.Monad (forM_)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import System.Directory (doesFileExist, removeFile)
import Data.Time (getCurrentTime, UTCTime(..), fromGregorian)
import Data.Maybe(isJust)
import Data.List(find)
import Data.Either (isLeft, isRight)
import Database.SQLite.Simple (execute, Only(..))

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
  , updateTournamentThirdPlaceMatch
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
import Shell.Persistence.SQLite.Error (PersistenceError(..))

import Domain.Participant (Participant(..), Player(..), PlayerName(..), Team(..), TeamName(..), TeamCaptain(..))
import Domain.Tournament
  ( TournamentName(..), OrganizerName(..), TournamentFormat(..)
  , Visibility(..), TournamentState(..), Tournament(..), TournamentId(..)
  )
import Domain.Tournament (ParticipantMode(..))
import Domain.Tournament (Game(..), TournamentDetails(..), noDetails, PublicStats(..))
import qualified Application.UseCases.CreateTournament as CTD
import qualified Application.UseCases.UpdateTournamentDetails as UTD
import qualified Engine.TournamentValidation as DV
import qualified Database.SQLite.Simple as SQLite
import qualified Application.UseCases.CreateTeam as CTM
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
import Shell.Persistence.SQLite.JoinRequestRepository ()
import Shell.Persistence.SQLite.NotificationRepository ()
import qualified Domain.Notification as Notif
import qualified Engine.Rankings as Rk
import qualified Application.UseCases.GetRankings as GRK
import Domain.JoinRequest (JoinRequestStatus(..))
import qualified Application.UseCases.RecordEFootballResult as REF
import qualified Application.UseCases.UpdateTournamentName as UTN
import qualified Application.UseCases.UpdateTournamentMaxParticipants as UTM
import qualified Domain.Participant as DPart
import qualified Engine.BracketGeneration as BracketGeneration
import qualified Engine.Seeding           as Seeding
import Domain.Bracket (Bracket(..), BracketNode(..), BracketNodeId(..), BracketSide(..), MatchSlot(..),BracketId(..))
import Application.UseCases.GetRoundRobinStandings (getRoundRobinStandings, GetRoundRobinStandingsError(..))
import Engine.Standings (Standing(..))
import qualified Engine.Standings as Standings
import qualified Application.UseCases.GetRoundRobinStandings as GRRS
import qualified Application.UseCases.GetRoundRobinStandings as GetRoundRobinStandings
import Application.UseCases.CorrectMatchResult(correctMatchResult,CorrectMatchResultError(..))
import System.IO (hSetBuffering, stdout, BufferMode(LineBuffering))
import Engine.Correction.DoubleEliminationLineage ( resolveWBWinnerTarget, resolveWBLoserTarget , resolveLBTarget , LineageError(..) )
import Application.UseCases.ReopenTournament (reopenTournament, ReopenTournamentError(..))
import qualified Application.UseCases.ReopenTournament as RT
import Application.UseCases.PauseTournament (pauseTournament, PauseTournamentError(..))
import qualified Application.UseCases.PauseTournament as PT
import Application.UseCases.ResumeTournament (resumeTournament, ResumeTournamentError(..))
import qualified Application.UseCases.ResumeTournament as RES
import qualified Application.UseCases.CorrectMatchResult as CMR
import Domain.TournamentHistory
  ( TournamentHistoryEntry(..)
  , TournamentHistoryEvent
      ( TournamentCreated, TournamentPublished, RegistrationOpened
      , RegistrationClosedEvent, BracketGenerated, TournamentStarted
      , TournamentCompleted, TournamentCancelled, TournamentResumed
      , ConfigurationChanged, TournamentReopened
      )
  )
import qualified Domain.TournamentHistory as TournamentHistory
import Application.UseCases.SetMatchSchedule (setMatchSchedule, SetMatchScheduleError(..))
import qualified Application.UseCases.SetMatchSchedule as SMS
import Application.UseCases.GetTournamentSchedule (getTournamentSchedule, GetTournamentScheduleError(..))
import qualified Application.UseCases.GetTournamentSchedule as GTS
import qualified Application.UseCases.CreateTournament as CTU
import qualified Application.UseCases.RegisterParticipant as RPC
import qualified Application.UseCases.UpdateTournamentRequireApproval as UTRA
import qualified Application.UseCases.JoinRequests as JRQ
import qualified Domain.TournamentHistory as ActH
import qualified Application.UseCases.CreateTournament as CreateApproval
import qualified Engine.TournamentValidation as TV
import qualified Application.UseCases.LoginUser as LU
import qualified Application.UseCases.RegisterUser as RU
import Shell.Infrastructure.PasswordHasher ()
import qualified Engine.User as EU
import qualified Application.UseCases.GetTournament as GetT
import qualified Application.UseCases.ListMyTournaments as ListMine
import Application.Internal.Authorization (AuthorizationError(..), requireAdministrator, requireVisibleToViewer)
import qualified Application.UseCases.ListPublicTournaments as LP
import Application.UseCases.UpdateTournamentThirdPlaceMatch (updateTournamentThirdPlaceMatch, UpdateTournamentThirdPlaceMatchError(..))
import qualified Application.UseCases.UpdateTournamentThirdPlaceMatch as UTTP
import qualified Control.Monad as BLM
import qualified Data.List as BLList
import qualified Domain.Bracket as BLBr
import qualified Domain.BracketLinks as BLLin
import qualified Domain.Ids as BLIds
import qualified Engine.BracketGeneration as BLGen
import qualified Engine.BracketLinks as BLEng
import qualified Engine.ByeResolution as BLBye
import qualified Engine.Correction.DoubleEliminationLineage as BLLD
import qualified Engine.Seeding as BLSeed
import qualified Application.UseCases.GetBracket as GBV
import qualified Data.Map.Strict as BLMap
import qualified Database.SQLite.Simple as BLSql


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

mkDeLineageParticipants :: Int -> [Participant]
mkDeLineageParticipants n =
  [ Individual (Player (PlayerName ("P" ++ show i))) | i <- [1 .. n] ]

wbNodesForDeLineage :: Int -> [BracketNode]
wbNodesForDeLineage n =
  filter ((== Winners) . nodeStage)
    (Seeding.seedParticipants
       (mkDeLineageParticipants n)
       (BracketGeneration.buildTopology (BracketGeneration.bracketSize n)))

wb4DeLineage, wb8DeLineage, wb6DeLineage :: [BracketNode]
wb4DeLineage = wbNodesForDeLineage 4
wb8DeLineage = wbNodesForDeLineage 8
wb6DeLineage = wbNodesForDeLineage 6

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

-- A fresh tournament already at RegistrationOpen, for registration tests.
createOpenTournament :: UserId -> String -> Int -> SQLiteM TournamentId
createOpenTournament ownerId name maxP =
  createOpenTournamentWithMode ownerId name maxP IndividualOnly

createOpenTournamentWithMode
  :: UserId -> String -> Int -> ParticipantMode -> SQLiteM TournamentId
createOpenTournamentWithMode ownerId name maxP mode = do
  tid <- createTournament NewTournament
    { newTournamentName            = TournamentName name
    , newTournamentOrganizer       = OrganizerName "Test Organizer"
    , newTournamentOwner           = ownerId
    , newTournamentFormat          = SingleElimination
    , newTournamentVisibility      = Public
    , newTournamentMaxParticipants = maxP
    , newTournamentThirdPlaceMatch = False
    , newTournamentParticipantMode = mode
    }
  advanceToRegistrationOpen ownerId tid
  pure tid

-- A small valid team for participant-mode tests.
modeTestTeam :: Team
modeTestTeam = Team
  { teamName    = TeamName "Falcons"
  , teamCaptain = Player (PlayerName "Cap")
  , teamMembers = [Player (PlayerName "Cap"), Player (PlayerName "Mate")]
  }

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hspec spec

spec :: Spec
spec = before_ resetTestDb $ do

  bracketLinksSpec
  bracketLinksStoreSpec
  correctionNodeIdSpec
  bracketLinksGenerationSpec
  doubleElimNodeIdSpec
  doubleElimParitySpec
  bracketLinksViewSpec
  detailsSpec
  statsSpec
  publicFilterSpec
  upcomingFilterSpec
  prizePoolSpec
  descriptionSpec
  formatChangeSpec
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
        _ <- unwrap =<< cancelTournament ownerId tidDraft "no longer needed"

        tidPublished <- createTournament NewTournament
          { newTournamentName = TournamentName "Cancel From Published"
          , newTournamentOrganizer = OrganizerName "Test Organizer", newTournamentOwner = ownerId
          , newTournamentFormat = SingleElimination, newTournamentVisibility = Public
          , newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
        _ <- unwrap =<< publishTournament ownerId tidPublished
        _ <- unwrap =<< cancelTournament ownerId tidPublished "no longer needed"

        tidRegOpen <- createTournament NewTournament
          { newTournamentName = TournamentName "Cancel From RegOpen"
          , newTournamentOrganizer = OrganizerName "Test Organizer", newTournamentOwner = ownerId
          , newTournamentFormat = SingleElimination, newTournamentVisibility = Public
          , newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
        _ <- unwrap =<< publishTournament ownerId tidRegOpen
        _ <- unwrap =<< openRegistration ownerId tidRegOpen
        _ <- unwrap =<< cancelTournament ownerId tidRegOpen "no longer needed"

        tidRegClosed <- createTournament NewTournament
          { newTournamentName = TournamentName "Cancel From RegClosed"
          , newTournamentOrganizer = OrganizerName "Test Organizer", newTournamentOwner = ownerId
          , newTournamentFormat = SingleElimination, newTournamentVisibility = Public
          , newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
        advanceToRegistrationClosed ownerId tidRegClosed
        _ <- unwrap =<< cancelTournament ownerId tidRegClosed "no longer needed"

        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tidInProgress <- createTournament NewTournament
          { newTournamentName = TournamentName "Cancel From InProgress"
          , newTournamentOrganizer = OrganizerName "Test Organizer", newTournamentOwner = ownerId
          , newTournamentFormat = SingleElimination, newTournamentVisibility = Public
          , newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
            , tournamentOwner = UserId 1, tournamentThirdPlaceMatch = False, tournamentParticipantMode = IndividualOnly, tournamentGame = Nothing, tournamentStartTime = Nothing, tournamentPrize = Nothing, tournamentDescription = Nothing, tournamentRequireApproval = False, tournamentRegistrationDeadline = Nothing
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
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
        _ <- createTournament NewTournament
          { newTournamentName = TournamentName "Not Mine", newTournamentOrganizer = OrganizerName "x"
          , newTournamentOwner = otherId, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
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

    it "rejects a blank team name and does not save the team" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        let captain = Player (PlayerName "Alice")
            team = Team { teamName = TeamName "   ", teamCaptain = captain, teamMembers = [captain] }
        outcome <- createTeam team
        saved   <- Repo.teamExists (TeamName "   ")
        pure (outcome, saved)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, saved) -> do
          outcome `shouldBe` Left EmptyTeamName
          saved `shouldBe` False

    it "rejects a blank captain name" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        let captain = Player (PlayerName "")
            team = Team { teamName = TeamName "Blank Captain Squad", teamCaptain = captain, teamMembers = [captain] }
        outcome <- createTeam team
        saved   <- Repo.teamExists (TeamName "Blank Captain Squad")
        pure (outcome, saved)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, saved) -> do
          outcome `shouldBe` Left EmptyPlayerName
          saved `shouldBe` False

    it "rejects a blank member name" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        let captain = Player (PlayerName "Alice")
            ghost   = Player (PlayerName "  ")
            team = Team { teamName = TeamName "Blank Member Squad", teamCaptain = captain, teamMembers = [captain, ghost] }
        createTeam team

      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldBe` Left EmptyPlayerName

    it "rejects duplicate member names and does not save the team" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        let captain = Player (PlayerName "Alice")
            team = Team { teamName = TeamName "Twin Squad", teamCaptain = captain, teamMembers = [captain, captain] }
        outcome <- createTeam team
        saved   <- Repo.teamExists (TeamName "Twin Squad")
        pure (outcome, saved)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, saved) -> do
          outcome `shouldBe` Left DuplicateMemberNames
          saved `shouldBe` False

    it "checks a blank name before the captain rule" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        let captain = Player (PlayerName "Alice")
            bob     = Player (PlayerName "Bob")
            team = Team { teamName = TeamName "", teamCaptain = captain, teamMembers = [bob] }
        createTeam team

      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldBe` Left EmptyTeamName

    it "checks duplicate members before the captain rule" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        let captain = Player (PlayerName "Alice")
            bob     = Player (PlayerName "Bob")
            team = Team { teamName = TeamName "Dup Before Captain", teamCaptain = captain, teamMembers = [bob, bob] }
        createTeam team

      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldBe` Left DuplicateMemberNames

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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
        _ <- createTournament NewTournament
          { newTournamentName = TournamentName "Owner2 Cup", newTournamentOrganizer = OrganizerName "x"
          , newTournamentOwner = owner2, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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

    it "retracts the reset match when GF1 is corrected from ResetRequired to Decisive" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "de-corr-gf1-retract-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            carol = Individual (Player (PlayerName "Carol"))
            dave  = Individual (Player (PlayerName "Dave"))
            participants = [alice, bob, carol, dave]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "GF1 Retraction Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = DoubleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
        -- Bob (LB champion) upsets Alice -- forces a reset, same as the
        -- existing reset-path test.
        playWinner bob scheduled3

        afterGF1 <- Repo.listMatchesForBracket bracketId
        let resetScheduled = filter (\m -> matchStatus m == Scheduled) afterGF1
        liftIO $ length resetScheduled `shouldBe` 1
        let resetMatchId = matchId (head resetScheduled)

        -- Admin realizes GF1 was scored wrong -- Alice actually won.
        -- Reset match is still Scheduled, unplayed.
        outcome <- correctMatchResult ownerId (matchId gf1Match) (Winner alice)

        allMatchesAfter <- Repo.listMatchesForBracket bracketId
        completion <- completeTournament ownerId tid

        pure (outcome, resetMatchId, allMatchesAfter, completion)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, resetMatchId, allMatchesAfter, completion) -> do
          outcome `shouldSatisfy` isRight
          case outcome of
            Right corrected -> matchOutcome corrected `shouldBe` Just (Winner (Individual (Player (PlayerName "Alice"))))
            Left _           -> expectationFailure "expected GF1 correction to succeed"
          -- The reset match must no longer exist in the bracket's match list.
          any (\m -> matchId m == resetMatchId) allMatchesAfter `shouldBe` False
          -- Completion must succeed immediately, with zero further action --
          -- confirms CompleteTournament.hs needed no changes for this.
          completion `shouldSatisfy` isRight
          case completion of
            Right t -> tournamentState t `shouldBe` Completed
            Left _  -> expectationFailure "expected completion to succeed after retraction"

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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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

    it "corrects a WB1 result before its downstream targets materialize" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "de-corr-wb1-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            carol = Individual (Player (PlayerName "Carol"))
            dave  = Individual (Player (PlayerName "Dave"))
            participants = [alice, bob, carol, dave]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "DoubleElim WB1 Correction Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = DoubleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
            original    = matchCompetitorA m
            replacement = matchCompetitorB m
        _ <- unwrap =<< startMatch ownerId (matchId m)
        _ <- unwrap =<< recordMatchResult ownerId (matchId m) (Winner original)

        -- Sibling WB1 match deliberately left unplayed -- both of this
        -- match's downstream targets (WB Final, LB1) require BOTH WB1
        -- results, so neither should be materialized yet.
        beforeCorrection <- Repo.listMatchesForBracket bracketId

        outcome <- correctMatchResult ownerId (matchId m) (Winner replacement)

        afterCorrection <- Repo.listMatchesForBracket bracketId
        matchAfter <- Repo.getMatch (matchId m)

        pure (outcome, replacement, length beforeCorrection, length afterCorrection, matchAfter)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, replacement, countBefore, countAfter, matchAfter) -> do
          outcome `shouldSatisfy` isRight
          matchOutcome matchAfter `shouldBe` Just (Winner replacement)
          -- Correction of a WB1 result whose downstream targets don't yet
          -- exist must not trigger or corrupt any materialization.
          countBefore `shouldBe` 2
          countAfter  `shouldBe` 2

    it "DE WB1 correction repairs bracket node slots (winner target and loser target)" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "de-slot-repair-owner"
        let participants =
              [ Individual (Player (PlayerName n)) | n <- ["Alice","Bob","Carol","Dave"] ]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "DE Slot Repair Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = DoubleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
            original    = matchCompetitorA m
            replacement = matchCompetitorB m
        _ <- unwrap =<< startMatch ownerId (matchId m)
        _ <- unwrap =<< recordMatchResult ownerId (matchId m) (Winner original)
        _ <- unwrap =<< correctMatchResult ownerId (matchId m) (Winner replacement)

        (_, nodes) <- Repo.getBracket bracketId
        -- WB round 1 nodes hold both competitors by design; every other node
        -- that holds a participant got it by propagation.
        let holders p =
              [ nodeStage n
              | n <- nodes
              , not (nodeRound n == 1 && nodeStage n == Winners)
              , Filled p `elem` [nodeSlotA n, nodeSlotB n] ]
        pure (holders replacement, holders original)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (replacementHolders, originalHolders) -> do
          replacementHolders `shouldBe` [Winners]   -- new winner sits in the next WB node
          originalHolders    `shouldBe` [Losers]    -- new loser dropped into the LB node
    forM_ [0, 1 :: Int] $ \i ->
      it ("DE correction leaves no stale copies in cascaded nodes (6 players, WB1 match " ++ show i ++ ")") $ do
        result <- runSQLiteM testDbPath $ do
          setupSchema
          ownerId <- createTestUser (if i == 0 then "de-cascade-owner-0" else "de-cascade-owner-1")
          let participants =
                [ Individual (Player (PlayerName ("P" ++ show k))) | k <- [1 .. 6 :: Int] ]
          tid <- createTournament NewTournament
            { newTournamentName            = TournamentName "DE Cascade Cup"
            , newTournamentOrganizer       = OrganizerName "Test Organizer"
            , newTournamentOwner           = ownerId
            , newTournamentFormat          = DoubleElimination
            , newTournamentVisibility      = Public
            , newTournamentMaxParticipants = 8
            , newTournamentThirdPlaceMatch = False
            , newTournamentParticipantMode = IndividualOnly
            }
          forM_ participants $ \p -> case p of
            Individual player -> Repo.savePlayer player
            Squad team         -> Repo.saveTeam team
          advanceToRegistrationOpen ownerId tid
          forM_ participants (\p -> unwrap =<< registerParticipant tid p)
          _ <- unwrap =<< closeRegistration ownerId tid
          bracketId <- unwrap =<< generateBracket ownerId tid

          (_, nodes0) <- Repo.getBracket bracketId
          ms <- Repo.listMatchesForBracket bracketId
          let wb1Ids = [ nodeId n | n <- nodes0, nodeRound n == 1, nodeStage n == Winners ]
              realWb1 = [ x | x <- ms, matchBracketNode x `elem` wb1Ids ]
              m = realWb1 !! i
              original    = matchCompetitorA m
              replacement = matchCompetitorB m
          _ <- unwrap =<< startMatch ownerId (matchId m)
          _ <- unwrap =<< recordMatchResult ownerId (matchId m) (Winner original)
          _ <- unwrap =<< correctMatchResult ownerId (matchId m) (Winner replacement)

          (_, nodes) <- Repo.getBracket bracketId
          let holds p n = Filled p `elem` [nodeSlotA n, nodeSlotB n]
              inLosers p = [ nodeId n | n <- nodes, nodeStage n == Losers, holds p n ]
              inWinnersBeyondR1 p =
                [ nodeId n | n <- nodes, nodeStage n == Winners, nodeRound n > 1, holds p n ]
          pure ( length realWb1, inLosers replacement, inLosers original
               , inWinnersBeyondR1 original )

        case result of
          Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
          Right (count, repLosers, origLosers, origWinners) -> do
            count `shouldSatisfy` (>= 2)
            repLosers `shouldBe` []                 -- new winner must be gone from every Losers node
            origWinners `shouldBe` []               -- new loser must not linger in WB round 2+
            origLosers `shouldSatisfy` (not . null) -- new loser must have dropped into the LB
    it "DE GF1 retraction voids the reset node (ResetRequired -> Decisive)" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "de-reset-void-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            carol = Individual (Player (PlayerName "Carol"))
            dave  = Individual (Player (PlayerName "Dave"))
            participants = [alice, bob, carol, dave]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "DE Reset Void Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = DoubleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
            gf1Match = head (filter (\x -> matchCompetitorA x == bob || matchCompetitorB x == bob) scheduled3)
        -- Bob (LB champion) upsets Alice: reset needed, reset match materializes.
        playWinner bob scheduled3

        -- Retract: Alice wins GF1 after all, so no reset is needed.
        _ <- unwrap =<< correctMatchResult ownerId (matchId gf1Match) (Winner alice)

        (bracket, nodes) <- Repo.getBracket bracketId
        afterCorrection <- Repo.listMatchesForBracket bracketId
        let resetNode = do
              rid <- bracketResetNodeId bracket
              find ((== rid) . nodeId) nodes
            resetMatchesLeft =
              [ x | Just rid <- [bracketResetNodeId bracket], x <- afterCorrection, matchBracketNode x == rid ]
        pure (fmap nodeSlotA resetNode, fmap nodeSlotB resetNode, length resetMatchesLeft)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (slotA, slotB, resetCount) -> do
          resetCount `shouldBe` 0                 -- the retraction already deletes the reset match
          slotA `shouldBe` Just ByeSlot           -- node must be voided like record does
          slotB `shouldBe` Just ByeSlot
    forM_ [ (SingleElimination, "adv-guard-se-owner", "SE")
          , (DoubleElimination, "adv-guard-de-owner", "DE") ] $ \(fmt, uname, label) ->
      it ("refuses to correct an elimination match to Draw or NoContest (" ++ label ++ ")") $ do
        result <- runSQLiteM testDbPath $ do
          setupSchema
          ownerId <- createTestUser uname
          let participants =
                [ Individual (Player (PlayerName n)) | n <- ["Alice","Bob","Carol","Dave"] ]
          tid <- createTournament NewTournament
            { newTournamentName            = TournamentName "Advanceable Guard Cup"
            , newTournamentOrganizer       = OrganizerName "Test Organizer"
            , newTournamentOwner           = ownerId
            , newTournamentFormat          = fmt
            , newTournamentVisibility      = Public
            , newTournamentMaxParticipants = 4
            , newTournamentThirdPlaceMatch = False
            , newTournamentParticipantMode = IndividualOnly
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
          before     <- Repo.getMatch (matchId m)
          rDraw      <- correctMatchResult ownerId (matchId m) Draw
          rNoContest <- correctMatchResult ownerId (matchId m) NoContest
          after      <- Repo.getMatch (matchId m)
          pure (rDraw, rNoContest, matchOutcome before, matchOutcome after)

        case result of
          Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
          Right (rDraw, rNoContest, before, after) -> do
            rDraw      `shouldSatisfy` either (const True) (const False)
            rNoContest `shouldSatisfy` either (const True) (const False)
            after `shouldBe` before   -- a refused correction must not touch the stored outcome
    it "plain correction deletes the stale eFootball score" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "ef-corr-delete-owner"
        let participants =
              [ Individual (Player (PlayerName n)) | n <- ["Alice","Bob","Carol","Dave"] ]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "EF Correction Delete Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid

        r1 <- Repo.listMatchesForBracket bracketId
        let m = head r1
            Right scoreA = mkEFootballScore 3
            Right scoreB = mkEFootballScore 1
        _ <- unwrap =<< startMatch ownerId (matchId m)
        _ <- unwrap =<< recordEFootballResult ownerId (matchId m) scoreA scoreB
        -- Plain correction: the winner flips, no goals supplied.
        _ <- unwrap =<< correctMatchResult ownerId (matchId m) (Winner (matchCompetitorB m))
        Repo.getEFootballScore (matchId m)

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right stored -> stored `shouldBe` Nothing   -- 3-1 would now contradict the winner
    it "correctEFootballResult replaces the score, overwrites it when the winner holds, and refuses a tied correction" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "ef-correct-goals-owner"
        let participants =
              [ Individual (Player (PlayerName n)) | n <- ["Alice","Bob","Carol","Dave"] ]
            sc n = either (error "bad score") id (mkEFootballScore n)
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "EF Correct Goals Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
            m2 = r1 !! 1
        forM_ [m1, m2] $ \m -> do
          _ <- unwrap =<< startMatch ownerId (matchId m)
          _ <- unwrap =<< recordEFootballResult ownerId (matchId m) (sc 3) (sc 1)
          pure ()

        -- 1. winner flips, goals supplied: score replaced
        flipped <- unwrap =<< REF.correctEFootballResult ownerId (matchId m1) (sc 0) (sc 2)
        s1 <- Repo.getEFootballScore (matchId m1)
        -- 2. winner holds, goals change: score overwritten
        _ <- unwrap =<< REF.correctEFootballResult ownerId (matchId m2) (sc 5) (sc 0)
        s2 <- Repo.getEFootballScore (matchId m2)
        -- 3. tied goals on an elimination match: refused, stored score untouched
        tied <- REF.correctEFootballResult ownerId (matchId m1) (sc 2) (sc 2)
        s1again <- Repo.getEFootballScore (matchId m1)

        pure ( matchOutcome flipped == Just (Winner (matchCompetitorB m1))
             , s1 == Just (sc 0, sc 2)
             , s2 == Just (sc 5, sc 0)
             , fmap (const ()) tied == Left (REF.EFootballCorrectionFailed (CMR.CorrectedOutcomeNotAdvanceable Draw))
             , s1again == Just (sc 0, sc 2) )

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right flags -> flags `shouldBe` (True, True, True, True, True)
    it "listTeams returns every saved team, ordered by name ignoring case" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        let mk n ps = DPart.Team
              { DPart.teamName    = DPart.TeamName n
              , DPart.teamCaptain = DPart.Player (DPart.PlayerName (head ps))
              , DPart.teamMembers = map (DPart.Player . DPart.PlayerName) ps }
        forM_ [mk "zebras" ["z1","z2"], mk "Alphas" ["a1","a2"], mk "bears" ["b1","b2"]] $ \t -> do
          mapM_ Repo.savePlayer (DPart.teamMembers t)
          Repo.saveTeam t
        ts <- Repo.listTeams
        pure (map (\t -> let DPart.TeamName n = DPart.teamName t in n) ts)
      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right names -> names `shouldBe` ["Alphas", "bears", "zebras"]
    it "updateTournamentName rejects a blank name and leaves the tournament unchanged" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "upd-name-owner"
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Original Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 8
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
          }
        before <- Repo.getTournament tid
        r      <- UTN.updateTournamentName ownerId tid (TournamentName "   ")
        after  <- Repo.getTournament tid
        pure (r, before, after)
      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (r, before, after) -> do
          r     `shouldSatisfy` either (const True) (const False)
          after `shouldBe` before

    it "updateTournamentMaxParticipants rejects a maximum below 2 and leaves the tournament unchanged" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "upd-max-owner"
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Max Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 8
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
          }
        before <- Repo.getTournament tid
        r0     <- UTM.updateTournamentMaxParticipants ownerId tid 0
        r1     <- UTM.updateTournamentMaxParticipants ownerId tid (-5)
        after  <- Repo.getTournament tid
        pure (r0, r1, before, after)
      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (r0, r1, before, after) -> do
          r0    `shouldSatisfy` either (const True) (const False)
          r1    `shouldSatisfy` either (const True) (const False)
          after `shouldBe` before
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
        [ (Filled p2, Filled p3)
        , (Filled p1, Filled p3)
        , (Filled p1, Filled p2)
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
        [ (Filled p1, Filled p4)
        , (Filled p2, Filled p3)
        , (Filled p1, Filled p3)
        , (Filled p2, Filled p4)
        , (Filled p1, Filled p2)
        , (Filled p3, Filled p4)
        ]

    it "spreads round robin matches so no player plays many in a row (n = 3..20)" $
      forM_ [3 .. 20 :: Int] $ \n -> do
        let ps = [ Individual (Player (PlayerName ("P" ++ show i))) | i <- [1 .. n] ]
            pairs = rrNodePairs ps (BracketGeneration.buildRoundRobinTopology ps)
            expected = [ (i, j) | i <- [1 .. n], j <- [i + 1 .. n] ]
        length pairs `shouldBe` length expected
        all (`elem` pairs) expected `shouldBe` True
        rrLongestStreak n pairs `shouldSatisfy` (<= (if n <= 4 then 2 else 1))
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
            , matchScheduledStart = Nothing
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
            , matchScheduledStart = Nothing
            }
          matches = [ mkMatch 1 a b (Winner a), mkMatch 2 b c (Winner b), mkMatch 3 c a (Winner c) ]
          standings = Standings.computeStandings matches
      map standingParticipant standings `shouldBe` [a, b, c]
      map standingPoints standings `shouldBe` [3, 3, 3]

    it "orders players level on points by goal difference (computeStandingsWith)" $ do
      let a = Individual (Player (PlayerName "A"))
          b = Individual (Player (PlayerName "B"))
          c = Individual (Player (PlayerName "C"))
          mkMatch i cA cB outcome = Match
            { matchId = MatchId i, matchTournament = TournamentId 0
            , matchBracket = BracketId 0, matchBracketNode = BracketNodeId (fromIntegral i)
            , matchCompetitorA = cA, matchCompetitorB = cB
            , matchStatus = Match.Completed, matchOutcome = Just outcome
            , matchScheduledStart = Nothing
            }
          matches = [ mkMatch 1 a b (Winner a), mkMatch 2 b c (Winner b), mkMatch 3 c a (Winner c) ]
          scores = [ (MatchId 1, (3, 0)), (MatchId 2, (1, 0)), (MatchId 3, (1, 0)) ]
          standings = Standings.computeStandingsWith scores matches
      map standingParticipant standings `shouldBe` [a, c, b]
      map standingGoalsFor standings `shouldBe` [3, 1, 1]
      map standingGoalsAgainst standings `shouldBe` [1, 1, 3]

    it "orders players level on points and goal difference by goals scored (computeStandingsWith)" $ do
      let a = Individual (Player (PlayerName "A"))
          b = Individual (Player (PlayerName "B"))
          c = Individual (Player (PlayerName "C"))
          mkMatch i cA cB outcome = Match
            { matchId = MatchId i, matchTournament = TournamentId 0
            , matchBracket = BracketId 0, matchBracketNode = BracketNodeId (fromIntegral i)
            , matchCompetitorA = cA, matchCompetitorB = cB
            , matchStatus = Match.Completed, matchOutcome = Just outcome
            , matchScheduledStart = Nothing
            }
          matches = [ mkMatch 1 a b (Winner a), mkMatch 2 b c (Winner b), mkMatch 3 c a (Winner c) ]
          scores = [ (MatchId 1, (2, 1)), (MatchId 2, (3, 2)), (MatchId 3, (4, 3)) ]
          standings = Standings.computeStandingsWith scores matches
      map Standings.standingGoalDifference standings `shouldBe` [0, 0, 0]
      map standingParticipant standings `shouldBe` [c, a, b]

    it "counts a match without a score for points only (computeStandingsWith)" $ do
      let a = Individual (Player (PlayerName "A"))
          b = Individual (Player (PlayerName "B"))
          c = Individual (Player (PlayerName "C"))
          mkMatch i cA cB outcome = Match
            { matchId = MatchId i, matchTournament = TournamentId 0
            , matchBracket = BracketId 0, matchBracketNode = BracketNodeId (fromIntegral i)
            , matchCompetitorA = cA, matchCompetitorB = cB
            , matchStatus = Match.Completed, matchOutcome = Just outcome
            , matchScheduledStart = Nothing
            }
          matches = [ mkMatch 1 a b (Winner a), mkMatch 2 a c (Forfeit a) ]
          scores = [ (MatchId 1, (2, 0)) ]
          standings = Standings.computeStandingsWith scores matches
      map standingPoints standings `shouldBe` [6, 0, 0]
      map standingParticipant standings `shouldBe` [a, c, b]
      map standingGoalsFor standings `shouldBe` [2, 0, 0]
      map standingGoalsAgainst standings `shouldBe` [0, 0, 2]
  describe "GetRoundRobinStandings" $ do

    it "rejects a non-RoundRobin tournament" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "grs-owner-notrr"
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "Not RoundRobin Cup", newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
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
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 3
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
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
          , newTournamentVisibility = Private, newTournamentMaxParticipants = 3
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
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
          , newTournamentVisibility = Private, newTournamentMaxParticipants = 3
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
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
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 3
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
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
            head standings `shouldBe` Standing alice 6 0 0


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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
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
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 5
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
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
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
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
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
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
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 5
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
          , newTournamentMaxParticipants = 8
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }

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

  describe "DoubleEliminationLineage (v0.9.1 Layer 1, pure)" $ do

    describe "resolveWBWinnerTarget" $ do
      context "n=4" $ do
        it "WB R1 node1 targets the WB Final (node3)" $
          resolveWBWinnerTarget 4 (BracketNodeId 1) `shouldBe` Just (BracketNodeId 3)
        it "WB R1 node2 targets the WB Final (node3)" $
          resolveWBWinnerTarget 4 (BracketNodeId 2) `shouldBe` Just (BracketNodeId 3)
        it "the WB Final (node3) has no WB-internal target" $
          resolveWBWinnerTarget 4 (BracketNodeId 3) `shouldBe` Nothing
      context "n=8" $ do
        it "WB R1 node1 targets R2 node5" $
          resolveWBWinnerTarget 8 (BracketNodeId 1) `shouldBe` Just (BracketNodeId 5)
        it "WB R1 node3 targets R2 node6" $
          resolveWBWinnerTarget 8 (BracketNodeId 3) `shouldBe` Just (BracketNodeId 6)
        it "R2 node5 targets the WB Final (node7)" $
          resolveWBWinnerTarget 8 (BracketNodeId 5) `shouldBe` Just (BracketNodeId 7)
        it "the WB Final (node7) has no WB-internal target" $
          resolveWBWinnerTarget 8 (BracketNodeId 7) `shouldBe` Nothing

    describe "resolveWBLoserTarget" $ do
      context "n=4" $ do
        it "WB R1 node1 -> LB1 (node4)" $
          resolveWBLoserTarget wb4DeLineage 4 (BracketNodeId 1) `shouldBe` Right (BracketNodeId 4)
        it "WB R1 node2 -> LB1 (node4)" $
          resolveWBLoserTarget wb4DeLineage 4 (BracketNodeId 2) `shouldBe` Right (BracketNodeId 4)
        it "WB Final node3 -> LB Final (node5)" $
          resolveWBLoserTarget wb4DeLineage 4 (BracketNodeId 3) `shouldBe` Right (BracketNodeId 5)
      context "n=8, no byes" $ do
        it "WB1 node1 -> LB1a (node8)" $
          resolveWBLoserTarget wb8DeLineage 8 (BracketNodeId 1) `shouldBe` Right (BracketNodeId 8)
        it "WB1 node2 -> LB1a (node8)" $
          resolveWBLoserTarget wb8DeLineage 8 (BracketNodeId 2) `shouldBe` Right (BracketNodeId 8)
        it "WB1 node3 -> LB1b (node9)" $
          resolveWBLoserTarget wb8DeLineage 8 (BracketNodeId 3) `shouldBe` Right (BracketNodeId 9)
        it "WB1 node4 -> LB1b (node9)" $
          resolveWBLoserTarget wb8DeLineage 8 (BracketNodeId 4) `shouldBe` Right (BracketNodeId 9)
        it "WB2 node5 -> LB2a (node10)" $
          resolveWBLoserTarget wb8DeLineage 8 (BracketNodeId 5) `shouldBe` Right (BracketNodeId 10)
        it "WB2 node6 -> LB2b (node11)" $
          resolveWBLoserTarget wb8DeLineage 8 (BracketNodeId 6) `shouldBe` Right (BracketNodeId 11)
        it "WB Final node7 -> LB Final (node13)" $
          resolveWBLoserTarget wb8DeLineage 8 (BracketNodeId 7) `shouldBe` Right (BracketNodeId 13)
      context "n=6, size=8, with byes (node1/node2 are byes)" $ do
        it "bye node1 has no loser target" $
          resolveWBLoserTarget wb6DeLineage 8 (BracketNodeId 1) `shouldBe` Left (NoLoserTarget (BracketNodeId 1))
        it "bye node2 has no loser target" $
          resolveWBLoserTarget wb6DeLineage 8 (BracketNodeId 2) `shouldBe` Left (NoLoserTarget (BracketNodeId 2))
        it "real-match node3 -> LB1 (node8)" $
          resolveWBLoserTarget wb6DeLineage 8 (BracketNodeId 3) `shouldBe` Right (BracketNodeId 8)
        it "real-match node4 -> LB1 (node8)" $
          resolveWBLoserTarget wb6DeLineage 8 (BracketNodeId 4) `shouldBe` Right (BracketNodeId 8)
        it "WB2 node5 -> node9" $
          resolveWBLoserTarget wb6DeLineage 8 (BracketNodeId 5) `shouldBe` Right (BracketNodeId 9)
        it "WB2 node6 -> node10 (the orphan-fed LB node)" $
          resolveWBLoserTarget wb6DeLineage 8 (BracketNodeId 6) `shouldBe` Right (BracketNodeId 10)
        it "WB Final node7 -> LB Final (node12)" $
          resolveWBLoserTarget wb6DeLineage 8 (BracketNodeId 7) `shouldBe` Right (BracketNodeId 12)

    describe "resolveLBTarget" $ do
      context "n=4" $
        it "LB1 (node4) -> LB Final (node5)" $
          resolveLBTarget wb4DeLineage 4 (BracketNodeId 4) `shouldBe` Just (BracketNodeId 5)
      context "n=8, no byes" $ do
        it "LB1a (node8) -> LB2b (node11), cross-seeded" $
          resolveLBTarget wb8DeLineage 8 (BracketNodeId 8) `shouldBe` Just (BracketNodeId 11)
        it "LB1b (node9) -> LB2a (node10), cross-seeded" $
          resolveLBTarget wb8DeLineage 8 (BracketNodeId 9) `shouldBe` Just (BracketNodeId 10)
        it "LB2a (node10) -> LB3 (node12)" $
          resolveLBTarget wb8DeLineage 8 (BracketNodeId 10) `shouldBe` Just (BracketNodeId 12)
        it "LB2b (node11) -> LB3 (node12)" $
          resolveLBTarget wb8DeLineage 8 (BracketNodeId 11) `shouldBe` Just (BracketNodeId 12)
        it "LB3 (node12) -> LB Final (node13)" $
          resolveLBTarget wb8DeLineage 8 (BracketNodeId 12) `shouldBe` Just (BracketNodeId 13)
        it "LB Final (node13) has no LB-internal target" $
          resolveLBTarget wb8DeLineage 8 (BracketNodeId 13) `shouldBe` Nothing
      context "n=6, size=8, with byes" $ do
        it "LB1 (node8) -> node9" $
          resolveLBTarget wb6DeLineage 8 (BracketNodeId 8) `shouldBe` Just (BracketNodeId 9)
        it "the orphan/bye-shaped node10 still has a normal winner target" $
          resolveLBTarget wb6DeLineage 8 (BracketNodeId 10) `shouldBe` Just (BracketNodeId 11)
        it "node9 -> node11" $
          resolveLBTarget wb6DeLineage 8 (BracketNodeId 9) `shouldBe` Just (BracketNodeId 11)
        it "node11 -> LB Final (node12)" $
          resolveLBTarget wb6DeLineage 8 (BracketNodeId 11) `shouldBe` Just (BracketNodeId 12)
        it "LB Final (node12) has no LB-internal target" $
          resolveLBTarget wb6DeLineage 8 (BracketNodeId 12) `shouldBe` Nothing

  describe "ReopenTournament (v0.9.2)" $ do

    it "rejects reopening a tournament that isn't Completed" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "reopen-notcompleted-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Reopen Wrong State Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        _ <- unwrap =<< generateBracket ownerId tid
        _ <- unwrap =<< startTournament ownerId tid
        -- Deliberately still InProgress, not Completed.
        reopenTournament ownerId tid "checking a result"

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe`
          Left (RT.InvalidLifecycle (InvalidTransition InProgress Completed))

    it "rejects an empty reopening reason" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "reopen-emptyreason-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Reopen Empty Reason Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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

        reopenTournament ownerId tid ""

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left RT.EmptyReopeningReason

    it "rejects a whitespace-only reopening reason" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "reopen-blankreason-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Reopen Blank Reason Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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

        reopenTournament ownerId tid "   "

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left RT.EmptyReopeningReason

    it "rejects reopening from a non-owner" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId    <- createTestUser "reopen-owner"
        impostorId <- createTestUser "reopen-impostor"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Reopen Ownership Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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

        reopenTournament impostorId tid "checking a result"

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left (RT.Unauthorized NotTournamentOwner)

    it "reopens a Completed SE tournament, allows correcting only the root match, and can be re-completed" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "reopen-se-golden-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            carol = Individual (Player (PlayerName "Carol"))
            dave  = Individual (Player (PlayerName "Dave"))
            participants = [alice, bob, carol, dave]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Reopen SE Golden Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid

        semis <- Repo.listMatchesForBracket bracketId
        liftIO $ length semis `shouldBe` 2
        forM_ semis $ \m -> do
          _ <- unwrap =<< startMatch ownerId (matchId m)
          _ <- unwrap =<< recordMatchResult ownerId (matchId m) (Winner (matchCompetitorA m))
          pure ()

        afterSemis <- Repo.listMatchesForBracket bracketId
        let final = head (filter (\m -> matchStatus m == Scheduled) afterSemis)
            finalOriginalWinner = matchCompetitorA final
            finalReplacement    = matchCompetitorB final
            firstSemi           = head semis

        _ <- unwrap =<< startMatch ownerId (matchId final)
        _ <- unwrap =<< recordMatchResult ownerId (matchId final) (Winner finalOriginalWinner)

        _ <- unwrap =<< startTournament ownerId tid
        _ <- unwrap =<< completeTournament ownerId tid

        stateBeforeReopen <- Repo.getTournament tid

        _ <- unwrap =<< reopenTournament ownerId tid "wrong winner was recorded"

        stateAfterReopen <- Repo.getTournament tid

        -- Earlier round (a semi) must still be blocked -- the final's
        -- Completed status doesn't change just because the tournament
        -- lifecycle reopened.
        earlySemiBlocked <- correctMatchResult ownerId (matchId firstSemi)
          (Winner (matchCompetitorB firstSemi))

        -- The root/final match, with no downstream, must now be correctable.
        finalCorrected <- unwrap =<< correctMatchResult ownerId (matchId final)
          (Winner finalReplacement)

        -- completeTournament must work again via the existing machinery,
        -- no special-casing needed.
        recompleted <- unwrap =<< completeTournament ownerId tid

        pure (stateBeforeReopen, stateAfterReopen, earlySemiBlocked, finalCorrected, recompleted, finalReplacement)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (before, afterReopen, earlySemiBlocked, finalCorrected, recompleted, finalReplacement) -> do
          tournamentState before      `shouldBe` Completed
          tournamentState afterReopen `shouldBe` InProgress
          earlySemiBlocked `shouldSatisfy` isLeft   -- DownstreamMatchStarted, existing guard unchanged
          matchOutcome finalCorrected `shouldBe` Just (Winner finalReplacement)
          tournamentState recompleted `shouldBe` Completed

  describe "PauseTournament / ResumeTournament (v0.9.3)" $ do

    it "PauseTournament rejects a tournament that isn't InProgress" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "pause-wrongstate-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Pause Wrong State Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        _ <- unwrap =<< generateBracket ownerId tid
        -- Deliberately still RegistrationClosed, not InProgress.
        pauseTournament ownerId tid

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe`
          Left (PT.InvalidLifecycle (InvalidTransition RegistrationClosed InProgress))

    it "PauseTournament rejects a non-owner" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId    <- createTestUser "pause-owner"
        impostorId <- createTestUser "pause-impostor"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Pause Ownership Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        _ <- unwrap =<< generateBracket ownerId tid
        _ <- unwrap =<< startTournament ownerId tid

        pauseTournament impostorId tid

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left (PT.Unauthorized NotTournamentOwner)

    it "PauseTournament transitions InProgress to Paused" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "pause-success-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Pause Success Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        _ <- unwrap =<< generateBracket ownerId tid
        _ <- unwrap =<< startTournament ownerId tid

        _ <- unwrap =<< pauseTournament ownerId tid
        Repo.getTournament tid

      case result of
        Left err         -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right tournament -> tournamentState tournament `shouldBe` Paused

    it "ResumeTournament rejects a tournament that isn't Paused" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "resume-wrongstate-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Resume Wrong State Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        _ <- unwrap =<< generateBracket ownerId tid
        _ <- unwrap =<< startTournament ownerId tid
        -- Deliberately still InProgress, never paused.
        resumeTournament ownerId tid

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe`
          Left (RES.InvalidLifecycle (InvalidTransition InProgress Paused))

    it "ResumeTournament rejects a non-owner" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId    <- createTestUser "resume-owner"
        impostorId <- createTestUser "resume-impostor"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Resume Ownership Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        _ <- unwrap =<< generateBracket ownerId tid
        _ <- unwrap =<< startTournament ownerId tid
        _ <- unwrap =<< pauseTournament ownerId tid

        resumeTournament impostorId tid

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left (RES.Unauthorized NotTournamentOwner)

    it "ResumeTournament transitions Paused back to InProgress" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "resume-success-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Resume Success Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        _ <- unwrap =<< generateBracket ownerId tid
        _ <- unwrap =<< startTournament ownerId tid
        _ <- unwrap =<< pauseTournament ownerId tid

        _ <- unwrap =<< resumeTournament ownerId tid
        Repo.getTournament tid

      case result of
        Left err         -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right tournament -> tournamentState tournament `shouldBe` InProgress

  describe "Operational guards: Paused / Cancelled (v0.9.3)" $ do

    it "StartMatch rejects a Paused tournament" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "opguard-startmatch-paused-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "OpGuard StartMatch Paused Cup"
          , newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        _ <- unwrap =<< startTournament ownerId tid
        _ <- unwrap =<< pauseTournament ownerId tid

        matches <- Repo.listMatchesForBracket bracketId
        startMatch ownerId (matchId (head matches))

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left (SM.InvalidLifecycle (ForbiddenState Paused))

    it "StartMatch rejects a Cancelled tournament" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "opguard-startmatch-cancelled-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "OpGuard StartMatch Cancelled Cup"
          , newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        _ <- unwrap =<< startTournament ownerId tid
        _ <- unwrap =<< cancelTournament ownerId tid "operational guard test"

        matches <- Repo.listMatchesForBracket bracketId
        startMatch ownerId (matchId (head matches))

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left (SM.InvalidLifecycle (ForbiddenState Cancelled))

    it "RecordMatchResult rejects a Paused tournament, even for an already-InProgress match" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "opguard-record-paused-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "OpGuard Record Paused Cup"
          , newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        _ <- unwrap =<< startTournament ownerId tid
        matches <- Repo.listMatchesForBracket bracketId
        let m = head matches
        _ <- unwrap =<< startMatch ownerId (matchId m)
        -- Hard pause: the match was ALREADY InProgress before pausing --
        -- confirms pause blocks recording, not just starting.
        _ <- unwrap =<< pauseTournament ownerId tid

        recordMatchResult ownerId (matchId m) (Winner (matchCompetitorA m))

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left (RMR.InvalidLifecycle (ForbiddenState Paused))

    it "RecordMatchResult rejects a Cancelled tournament" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "opguard-record-cancelled-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "OpGuard Record Cancelled Cup"
          , newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        _ <- unwrap =<< startTournament ownerId tid
        matches <- Repo.listMatchesForBracket bracketId
        let m = head matches
        _ <- unwrap =<< startMatch ownerId (matchId m)
        _ <- unwrap =<< cancelTournament ownerId tid "operational guard test"

        recordMatchResult ownerId (matchId m) (Winner (matchCompetitorA m))

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left (RMR.InvalidLifecycle (ForbiddenState Cancelled))

    it "CompleteTournament rejects a Paused tournament" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "opguard-complete-paused-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "OpGuard Complete Paused Cup"
          , newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        _ <- unwrap =<< startTournament ownerId tid
        matches <- Repo.listMatchesForBracket bracketId
        let m = head matches
        _ <- unwrap =<< startMatch ownerId (matchId m)
        _ <- unwrap =<< recordMatchResult ownerId (matchId m) (Winner (matchCompetitorA m))
        -- All matches Completed -- would normally satisfy completion --
        -- but paused AFTER, so the Paused check must still block it.
        _ <- unwrap =<< pauseTournament ownerId tid

        completeTournament ownerId tid

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left (CT.InvalidCompletion TournamentPaused)

    it "CorrectMatchResult (DoubleElimination) rejects a Paused tournament" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "opguard-correct-de-paused-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            carol = Individual (Player (PlayerName "Carol"))
            dave  = Individual (Player (PlayerName "Dave"))
            participants = [alice, bob, carol, dave]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "OpGuard Correct DE Paused Cup"
          , newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = DoubleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        _ <- unwrap =<< startTournament ownerId tid
        wb1 <- Repo.listMatchesForBracket bracketId
        let m = head wb1
        _ <- unwrap =<< startMatch ownerId (matchId m)
        _ <- unwrap =<< recordMatchResult ownerId (matchId m) (Winner (matchCompetitorA m))
        _ <- unwrap =<< pauseTournament ownerId tid

        correctMatchResult ownerId (matchId m) (Winner (matchCompetitorB m))

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left (CMR.InvalidLifecycle (ForbiddenState Paused))

    it "CorrectMatchResult (DoubleElimination) rejects a Cancelled tournament" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "opguard-correct-de-cancelled-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            carol = Individual (Player (PlayerName "Carol"))
            dave  = Individual (Player (PlayerName "Dave"))
            participants = [alice, bob, carol, dave]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "OpGuard Correct DE Cancelled Cup"
          , newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = DoubleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        _ <- unwrap =<< startTournament ownerId tid
        wb1 <- Repo.listMatchesForBracket bracketId
        let m = head wb1
        _ <- unwrap =<< startMatch ownerId (matchId m)
        _ <- unwrap =<< recordMatchResult ownerId (matchId m) (Winner (matchCompetitorA m))
        _ <- unwrap =<< cancelTournament ownerId tid "operational guard test"

        correctMatchResult ownerId (matchId m) (Winner (matchCompetitorB m))

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left (CMR.InvalidLifecycle (ForbiddenState Cancelled))

    it "CorrectMatchResult (RoundRobin) rejects a Paused tournament" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "opguard-correct-rr-paused-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            carol = Individual (Player (PlayerName "Carol"))
            participants = [alice, bob, carol]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "OpGuard Correct RR Paused Cup"
          , newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = RoundRobin
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 3
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        _ <- unwrap =<< startTournament ownerId tid
        matches <- Repo.listMatchesForBracket bracketId
        let m = head matches
        _ <- unwrap =<< startMatch ownerId (matchId m)
        _ <- unwrap =<< recordMatchResult ownerId (matchId m) (Winner (matchCompetitorA m))
        _ <- unwrap =<< pauseTournament ownerId tid

        correctMatchResult ownerId (matchId m) (Winner (matchCompetitorB m))

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left (CMR.InvalidLifecycle (ForbiddenState Paused))

    it "CorrectMatchResult (RoundRobin) rejects a Cancelled tournament" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "opguard-correct-rr-cancelled-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            carol = Individual (Player (PlayerName "Carol"))
            participants = [alice, bob, carol]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "OpGuard Correct RR Cancelled Cup"
          , newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = RoundRobin
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 3
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        _ <- unwrap =<< startTournament ownerId tid
        matches <- Repo.listMatchesForBracket bracketId
        let m = head matches
        _ <- unwrap =<< startMatch ownerId (matchId m)
        _ <- unwrap =<< recordMatchResult ownerId (matchId m) (Winner (matchCompetitorA m))
        _ <- unwrap =<< cancelTournament ownerId tid "operational guard test"

        correctMatchResult ownerId (matchId m) (Winner (matchCompetitorB m))

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left (CMR.InvalidLifecycle (ForbiddenState Cancelled))

  describe "DE-shape reopening (v0.9.2 Thread A, DE-specific)" $ do

    it "reopens a Completed DE tournament (Shape 2: reset played) and allows correcting the reset match" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "reopen-de-shape2-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            carol = Individual (Player (PlayerName "Carol"))
            dave  = Individual (Player (PlayerName "Dave"))
            participants = [alice, bob, carol, dave]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Reopen DE Shape2 Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = DoubleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
        -- Bob (LB champion) upsets Alice -- forces a reset (Shape 2).
        playWinner bob scheduled3

        afterGF1 <- Repo.listMatchesForBracket bracketId
        let resetScheduled = filter (\m -> matchStatus m == Scheduled) afterGF1
            resetMatch = head resetScheduled
        _ <- unwrap =<< startMatch ownerId (matchId resetMatch)
        _ <- unwrap =<< recordMatchResult ownerId (matchId resetMatch) (Winner bob)

        _ <- unwrap =<< startTournament ownerId tid
        _ <- unwrap =<< completeTournament ownerId tid

        stateBeforeReopen <- Repo.getTournament tid
        _ <- unwrap =<< reopenTournament ownerId tid "double-checking the reset result"
        stateAfterReopen <- Repo.getTournament tid

        -- The reset match is the true root in Shape 2 -- no downstream,
        -- so it must be correctable, same as SE's root.
        correction <- correctMatchResult ownerId (matchId resetMatch) (Winner alice)

        recompleted <- unwrap =<< completeTournament ownerId tid

        pure (stateBeforeReopen, stateAfterReopen, correction, recompleted)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (before, afterReopen, correction, recompleted) -> do
          tournamentState before      `shouldBe` Completed
          tournamentState afterReopen `shouldBe` InProgress
          correction `shouldSatisfy` isRight
          case correction of
            Right corrected -> matchOutcome corrected `shouldBe` Just (Winner (Individual (Player (PlayerName "Alice"))))
            Left _           -> expectationFailure "expected reset match correction to succeed"
          tournamentState recompleted `shouldBe` Completed

    it "reopens a Completed DE tournament (Shape 1: GF1 decisive, no reset) and rejects correcting GF1 to ResetRequired" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "reopen-de-shape1-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            carol = Individual (Player (PlayerName "Carol"))
            dave  = Individual (Player (PlayerName "Dave"))
            participants = [alice, bob, carol, dave]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Reopen DE Shape1 Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = DoubleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
        -- WB champion (Alice) wins outright -- Shape 1, no reset ever exists.
        playWinner alice scheduled3

        allAfterGF1 <- Repo.listMatchesForBracket bracketId
        liftIO $ any (\m -> matchStatus m == Scheduled) allAfterGF1 `shouldBe` False

        _ <- unwrap =<< startTournament ownerId tid
        _ <- unwrap =<< completeTournament ownerId tid

        _ <- unwrap =<< reopenTournament ownerId tid "double-checking GF1"

        -- Correcting GF1 to Bob (the LB champion) would require a reset
        -- that never existed -- must be explicitly rejected, not silently
        -- succeed and leave the bracket in a broken state.
        correction <- correctMatchResult ownerId (matchId gf1Match) (Winner bob)

        matchAfter <- Repo.getMatch (matchId gf1Match)

        pure (correction, matchAfter)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (correction, matchAfter) -> do
          correction `shouldBe` Left (GF1ResetNotRestorable (matchId matchAfter))
          matchOutcome matchAfter `shouldBe` Just (Winner (Individual (Player (PlayerName "Alice"))))

  describe "Transaction atomicity: GF1 retraction (v0.9.4 item 4)" $ do

    it "rolls back the GF1 correction if retracting the reset match fails mid-transaction" $ do
      setupResult <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "atomicity-gf1-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            carol = Individual (Player (PlayerName "Carol"))
            dave  = Individual (Player (PlayerName "Dave"))
            participants = [alice, bob, carol, dave]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "Atomicity GF1 Cup"
          , newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = DoubleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
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
        playWinner bob scheduled3

        afterGF1 <- Repo.listMatchesForBracket bracketId
        let resetScheduled = filter (\m -> matchStatus m == Scheduled) afterGF1
            resetMatch = head resetScheduled

        let Right scoreA = mkEFootballScore 1
            Right scoreB = mkEFootballScore 0
        Repo.saveEFootballScore (matchId resetMatch) scoreA scoreB

        pure (ownerId, matchId gf1Match, matchId resetMatch)

      case setupResult of
        Left err -> expectationFailure ("setup failed: " ++ show err)
        Right (ownerId, gf1MatchId, resetMatchId) -> do

          beforeResult <- runSQLiteM testDbPath $ do
            gf1Before   <- Repo.getMatch gf1MatchId
            resetBefore <- Repo.getMatch resetMatchId
            pure (gf1Before, resetBefore)

          -- The whole call is expected to fail here: deleteMatch's real
          -- FK violation escapes correctMatchResult's own withTxEither
          -- (which only catches its synthetic TxRollback signal) and
          -- surfaces at runSQLiteM's outer PersistenceError boundary --
          -- per ADR-007, that outer boundary, not each use case's own
          -- transaction, is the documented single translation point.
          correctionResult <- runSQLiteM testDbPath $
            correctMatchResult ownerId gf1MatchId (Winner (Individual (Player (PlayerName "Alice"))))

          afterResult <- runSQLiteM testDbPath $ do
            gf1After   <- Repo.getMatch gf1MatchId
            resetAfter <- Repo.getMatch resetMatchId
            pure (gf1After, resetAfter)

          case (beforeResult, correctionResult, afterResult) of
            (Right (gf1Before, resetBefore), Left _, Right (gf1After, resetAfter)) -> do
              matchOutcome gf1After   `shouldBe` matchOutcome gf1Before
              matchStatus  resetAfter `shouldBe` matchStatus  resetBefore
              matchOutcome resetAfter `shouldBe` matchOutcome resetBefore
            other -> expectationFailure ("unexpected shape: " ++ show other)
  describe "TournamentHistory round-trip (v0.9.4 item 5)" $ do

    it "records and correctly decodes Paused, Resumed, and Reopened events, in order, with reasons intact" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "history-roundtrip-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "History Round-Trip Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        _ <- unwrap =<< startTournament ownerId tid

        -- Pause / Resume while InProgress.
        _ <- unwrap =<< pauseTournament ownerId tid
        _ <- unwrap =<< resumeTournament ownerId tid

        -- Play to Completed, then Reopen with a real reason.
        matches <- Repo.listMatchesForBracket bracketId
        let m = head matches
        _ <- unwrap =<< startMatch ownerId (matchId m)
        _ <- unwrap =<< recordMatchResult ownerId (matchId m) (Winner (matchCompetitorA m))
        _ <- unwrap =<< completeTournament ownerId tid
        _ <- unwrap =<< reopenTournament ownerId tid "checking the final result"

        Repo.getTournamentHistory tid

      case result of
        Left err      -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right entries -> do
          let events = map historyEvent entries

          -- The three v0.9.2/v0.9.3 events must all be present, in the
          -- order they actually occurred -- not just individually
          -- decodable in isolation. This directly re-exercises the
          -- exact rowToEvent code path that had the catch-all-ordering
          -- bug earlier this session (silently returning
          -- StorageFailure via the wildcard instead of the real
          -- clause) -- a passing decode here proves the fix holds
          -- under a real write-then-read round trip, not just under
          -- compilation.
          TournamentHistory.TournamentPaused `elem` events `shouldBe` True
          TournamentResumed                  `elem` events `shouldBe` True

          let reopenedEvents = [ e | e@(TournamentReopened _) <- events ]
          case reopenedEvents of
            [TournamentReopened reason] ->
              reason `shouldBe` "checking the final result"
            other ->
              expectationFailure ("expected exactly one TournamentReopened event, got: " ++ show other)

          -- Order matters: Paused must precede Resumed (they can't be
          -- decoded correctly and still be out of sequence without
          -- something upstream being wrong).
          let pausedIdx  = length (takeWhile (/= TournamentHistory.TournamentPaused) events)
              resumedIdx = length (takeWhile (/= TournamentResumed) events)
          pausedIdx `shouldSatisfy` (< resumedIdx)

  describe "Match Scheduling persistence (v0.10)" $ do

    it "round-trips Nothing (a freshly materialized match has no scheduled start)" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "sched-nothing-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Schedule Nothing Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        matches <- Repo.listMatchesForBracket bracketId
        Repo.getMatch (matchId (head matches))

      case result of
        Left err        -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right fetched    -> matchScheduledStart fetched `shouldBe` Nothing

    it "round-trips a canonical UTCTime exactly through saveMatch/getMatch" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "sched-roundtrip-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Schedule Roundtrip Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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
            scheduled = UTCTime (fromGregorian 2026 9 15) (14 * 3600)  -- 2026-09-15T14:00:00Z

        Repo.saveMatch m { matchScheduledStart = Just scheduled }
        refetched <- Repo.getMatch (matchId m)
        pure (scheduled, refetched)

      case result of
        Left err                     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (scheduled, refetched) -> matchScheduledStart refetched `shouldBe` Just scheduled

    it "rejects a non-canonical scheduled_start value on read, rather than silently coercing" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "sched-corrupt-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Schedule Corrupt Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
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

        -- Deliberately bypass encodeScheduledStart entirely -- write a
        -- non-canonical (space-separated, sqlite-simple-default-shaped)
        -- string directly, the same shape audit_log.occurred_at actually
        -- persists. This state is only reachable by going around the
        -- codec, same rationale as the existing "defensive" tests.
        conn <- ask >>= \env -> pure (envConnection env)
        liftIO $ execute conn
          "UPDATE matches SET scheduled_start = ? WHERE id = ?"
          ("2026-09-15 14:00:00.000000" :: Text, unMatchId (matchId m))

        Repo.getMatch (matchId m)

      case result of
        Left (StorageFailure _) -> pure ()  -- expected: decode rejects, doesn't coerce
        Left other  -> expectationFailure ("expected StorageFailure, got: " ++ show other)
        Right m     -> expectationFailure
          ("expected getMatch to fail on non-canonical scheduled_start, got: " ++ show m)

  describe "SetMatchSchedule (v0.10)" $ do

    it "rejects a non-owner" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId    <- createTestUser "sms-owner"
        impostorId <- createTestUser "sms-impostor"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "SMS Ownership Cup"
          , newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        matches <- Repo.listMatchesForBracket bracketId
        let m = head matches
            scheduled = UTCTime (fromGregorian 2026 9 15) (14 * 3600)

        setMatchSchedule impostorId (matchId m) (Just scheduled)

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left (SMS.Unauthorized NotTournamentOwner)

    it "rejects a match that isn't Scheduled" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "sms-notscheduled-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "SMS NotScheduled Cup"
          , newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        matches <- Repo.listMatchesForBracket bracketId
        let m = head matches
            scheduled = UTCTime (fromGregorian 2026 9 15) (14 * 3600)
        _ <- unwrap =<< startMatch ownerId (matchId m)   -- now InProgress

        setMatchSchedule ownerId (matchId m) (Just scheduled)

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left (SMS.InvalidMatch (MatchNotScheduled Match.InProgress))

    it "rejects a Completed tournament" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "sms-completed-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "SMS Completed Cup"
          , newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        matches <- Repo.listMatchesForBracket bracketId
        let m = head matches
            scheduled = UTCTime (fromGregorian 2026 9 15) (14 * 3600)
        _ <- unwrap =<< startTournament ownerId tid
        _ <- unwrap =<< startMatch ownerId (matchId m)
        _ <- unwrap =<< recordMatchResult ownerId (matchId m) (Winner (matchCompetitorA m))
        _ <- unwrap =<< completeTournament ownerId tid

        setMatchSchedule ownerId (matchId m) (Just scheduled)

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left (SMS.InvalidLifecycle (ForbiddenState Completed))

    it "rejects a Cancelled tournament even when the match is still Scheduled" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "sms-cancelled-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "SMS Cancelled Cup"
          , newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        matches <- Repo.listMatchesForBracket bracketId
        let m = head matches
            scheduled = UTCTime (fromGregorian 2026 9 15) (14 * 3600)
        _ <- unwrap =<< startTournament ownerId tid
        _ <- unwrap =<< cancelTournament ownerId tid "SetMatchSchedule guard test"
        -- Match m is still Scheduled -- CancelTournament never touches
        -- match rows -- so this exercises the tournament-lifecycle
        -- branch specifically, not the match-status branch.

        setMatchSchedule ownerId (matchId m) (Just scheduled)

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldBe` Left (SMS.InvalidLifecycle (ForbiddenState Cancelled))

    it "succeeds while the tournament is Paused -- the guard's actual motivating case" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "sms-paused-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            carol = Individual (Player (PlayerName "Carol"))
            dave  = Individual (Player (PlayerName "Dave"))
            participants = [alice, bob, carol, dave]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "SMS Paused Cup"
          , newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        matches <- Repo.listMatchesForBracket bracketId
        let m = head matches   -- a semi -- still Scheduled, untouched
            scheduled = UTCTime (fromGregorian 2026 9 15) (14 * 3600)
        _ <- unwrap =<< startTournament ownerId tid
        _ <- unwrap =<< pauseTournament ownerId tid

        outcome <- setMatchSchedule ownerId (matchId m) (Just scheduled)
        pure (outcome, scheduled)

      case result of
        Left err                    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, scheduled)  -> case outcome of
          Left e         -> expectationFailure ("expected scheduling to succeed while Paused, got: " ++ show e)
          Right updated  -> matchScheduledStart updated `shouldBe` Just scheduled

    it "sets then clears a schedule through the use case itself, round-tripping via getMatch" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "sms-roundtrip-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "SMS Roundtrip Cup"
          , newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        matches <- Repo.listMatchesForBracket bracketId
        let m = head matches
            scheduled = UTCTime (fromGregorian 2026 9 15) (14 * 3600)

        _        <- unwrap =<< setMatchSchedule ownerId (matchId m) (Just scheduled)
        afterSet <- Repo.getMatch (matchId m)

        _          <- unwrap =<< setMatchSchedule ownerId (matchId m) Nothing
        afterClear <- Repo.getMatch (matchId m)

        pure (afterSet, afterClear)

      case result of
        Left err                        -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (afterSet, afterClear)    -> do
          matchScheduledStart afterSet   `shouldBe` Just (UTCTime (fromGregorian 2026 9 15) (14 * 3600))
          matchScheduledStart afterClear `shouldBe` Nothing

  describe "GetTournamentSchedule (v0.10)" $ do

    it "rejects when the bracket hasn't been generated yet" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "gts-owner-nobracket"
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "GTS No Bracket Cup", newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
        getTournamentSchedule ownerId tid
      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldBe` Left GTS.BracketNotGenerated

    it "rejects a non-owner viewing a Private tournament's schedule" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId    <- createTestUser "gts-owner-private"
        strangerId <- createTestUser "gts-stranger"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "GTS Private Cup", newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Private, newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
        forM_ participants $ \p -> case p of Individual player -> Repo.savePlayer player; Squad team -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        _ <- unwrap =<< generateBracket ownerId tid
        getTournamentSchedule strangerId tid
      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldBe` Left (GTS.Unauthorized NotAuthorizedToView)

    it "allows the owner to view a Private tournament's schedule" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "gts-owner-private2"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "GTS Private Owner Cup", newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Private, newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
        forM_ participants $ \p -> case p of Individual player -> Repo.savePlayer player; Squad team -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        _ <- unwrap =<< generateBracket ownerId tid
        getTournamentSchedule ownerId tid
      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> case inner of
          Left e  -> expectationFailure ("expected owner to view schedule, got: " ++ show e)
          Right _ -> pure ()

    it "allows any authenticated caller to view a Public tournament's schedule" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId    <- createTestUser "gts-owner-public"
        strangerId <- createTestUser "gts-stranger2"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "GTS Public Cup", newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
        forM_ participants $ \p -> case p of Individual player -> Repo.savePlayer player; Squad team -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        _ <- unwrap =<< generateBracket ownerId tid
        getTournamentSchedule strangerId tid
      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldSatisfy` isRight

    it "includes a Completed tournament's schedule (viewing isn't lifecycle-gated)" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "gts-completed-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "GTS Completed Cup", newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
        forM_ participants $ \p -> case p of Individual player -> Repo.savePlayer player; Squad team -> Repo.saveTeam team
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
        getTournamentSchedule ownerId tid
      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> case inner of
          Left e            -> expectationFailure ("expected Completed tournament's schedule to be viewable, got: " ++ show e)
          Right [scheduled] -> matchStatus scheduled `shouldBe` Match.Completed
          Right other       -> expectationFailure ("expected exactly one match, got: " ++ show other)

    it "orders scheduled matches ascending, with unscheduled matches last preserving original order" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "gts-order-owner"
        let participants = [ Individual (Player (PlayerName ("P" ++ show i))) | i <- [1 .. 8 :: Int] ]
        tid <- createTournament NewTournament
          { newTournamentName = TournamentName "GTS Order Cup", newTournamentOrganizer = OrganizerName "Test Organizer"
          , newTournamentOwner = ownerId, newTournamentFormat = SingleElimination
          , newTournamentVisibility = Public, newTournamentMaxParticipants = 8
          , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
        forM_ participants $ \p -> case p of Individual player -> Repo.savePlayer player; Squad team -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid

        r1 <- Repo.listMatchesForBracket bracketId   -- [m1, m2, m3, m4], ORDER BY id
        liftIO $ length r1 `shouldBe` 4
        let [m1, m2, m3, m4] = r1
            early = UTCTime (fromGregorian 2026 9 15) (10 * 3600)
            late  = UTCTime (fromGregorian 2026 9 15) (16 * 3600)

        -- m3 scheduled earliest, m1 scheduled later, m2 and m4 left
        -- unscheduled -- expected order: m3, m1, then m2, m4 (their
        -- original relative order preserved among the Nothing group).
        _ <- unwrap =<< setMatchSchedule ownerId (matchId m3) (Just early)
        _ <- unwrap =<< setMatchSchedule ownerId (matchId m1) (Just late)

        outcome <- getTournamentSchedule ownerId tid
        pure (outcome, matchId m1, matchId m2, matchId m3, matchId m4)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, id1, id2, id3, id4) -> case outcome of
          Left e         -> expectationFailure ("expected schedule query to succeed, got: " ++ show e)
          Right schedule -> map matchId schedule `shouldBe` [id3, id1, id2, id4]

  describe "Engine.TournamentValidation (pure)" $ do

    it "rejects a blank tournament name" $
      TV.validateTournamentFields (TournamentName "   ") (OrganizerName "Jae") 4
        `shouldBe` Left TV.EmptyName

    it "rejects a blank organizer" $
      TV.validateTournamentFields (TournamentName "Cup") (OrganizerName "") 4
        `shouldBe` Left TV.EmptyOrganizer

    it "rejects maxParticipants below 2" $
      TV.validateTournamentFields (TournamentName "Cup") (OrganizerName "Jae") 1
        `shouldBe` Left (TV.MaxParticipantsTooLow 1)

    it "accepts the smallest valid input" $
      TV.validateTournamentFields (TournamentName "Cup") (OrganizerName "Jae") 2
        `shouldBe` Right ()

    it "validateParticipant rejects a blank player name" $
      TV.validateParticipant (Individual (Player (PlayerName "  ")))
        `shouldBe` Left TV.BlankPlayerName

    it "validateParticipant accepts a named player" $
      TV.validateParticipant (Individual (Player (PlayerName "Alice")))
        `shouldBe` Right ()

  describe "CreateTournament (checked)" $ do

    it "rejects invalid input and persists nothing" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "ctc-owner-invalid"
        outcome <- CTU.createTournamentChecked NewTournament
          { newTournamentName            = TournamentName "   "
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
          }
        stored <- Repo.listAllTournaments
        pure (outcome, length stored)
      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, count) -> do
          outcome `shouldBe` Left (CTU.InvalidTournament TV.EmptyName)
          count `shouldBe` 0

    it "creates a tournament when the input is valid" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "ctc-owner-valid"
        outcome <- CTU.createTournamentChecked NewTournament
          { newTournamentName            = TournamentName "Valid Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
          }
        stored <- Repo.listAllTournaments
        pure (outcome, length stored)
      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, count) -> do
          outcome `shouldSatisfy` isRight
          count `shouldBe` 1

  describe "GenerateBracket idempotence guard" $ do

    it "rejects a second generateBracket and leaves the first bracket attached" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "gb-twice-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Generate Twice Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        firstBracket <- unwrap =<< generateBracket ownerId tid
        second       <- generateBracket ownerId tid
        tournament   <- Repo.getTournament tid
        matches      <- Repo.listMatchesForBracket firstBracket
        pure (firstBracket, second, tournamentBracket tournament, length matches)
      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (firstB, second, attached, matchCount) -> do
          second     `shouldBe` Left (GB.BracketAlreadyExists firstB)
          attached   `shouldBe` Just firstB
          matchCount `shouldBe` 1

  describe "RegisterParticipant (checked)" $ do

    it "registers a brand-new player without any pre-saving" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "rpc-owner-new"
        tid <- createOpenTournament ownerId "RPC New Player Cup" 4
        outcome <- RPC.registerParticipantChecked ownerId tid
          (Individual (Player (PlayerName "Alice")))
        regs <- Repo.listRegistrations tid
        pure (outcome, length regs)
      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, count) -> do
          outcome `shouldSatisfy` isRight
          count `shouldBe` 1

    it "rejects the same participant twice and keeps exactly one registration" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "rpc-owner-dup"
        tid <- createOpenTournament ownerId "RPC Duplicate Cup" 4
        let alice = Individual (Player (PlayerName "Alice"))
        firstTry  <- RPC.registerParticipantChecked ownerId tid alice
        secondTry <- RPC.registerParticipantChecked ownerId tid alice
        regs <- Repo.listRegistrations tid
        pure (firstTry, secondTry, length regs)
      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (firstTry, secondTry, count) -> do
          firstTry  `shouldSatisfy` isRight
          secondTry `shouldBe` Left RPC.AlreadyRegistered
          count     `shouldBe` 1

    it "stores and returns the participant mode a tournament was created with" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "rpc-owner-mode-rt"
        tid <- createOpenTournamentWithMode ownerId "Mode Round Trip Cup" 4 SquadOnly
        stored <- Repo.getTournament tid
        pure (tournamentParticipantMode stored)
      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right mode -> mode `shouldBe` SquadOnly

    it "rejects an Individual in a SquadOnly tournament and registers nothing" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "rpc-owner-mode-ind"
        tid <- createOpenTournamentWithMode ownerId "Squad Only Cup" 4 SquadOnly
        outcome <- RPC.registerParticipantChecked ownerId tid
          (Individual (Player (PlayerName "Alice")))
        regs <- Repo.listRegistrations tid
        pure (outcome, length regs)
      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, count) -> do
          outcome `shouldBe` Left (RPC.ParticipantKindNotAllowed SquadOnly)
          count   `shouldBe` 0

    it "does not save the player row when the participant kind is rejected" $ do
      setup <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "rpc-owner-mode-nosave"
        rejectedTid <- createOpenTournamentWithMode ownerId "No Save Cup" 4 SquadOnly
        controlTid  <- createOpenTournament ownerId "Control Cup" 4
        rejected <- RPC.registerParticipantChecked ownerId rejectedTid
          (Individual (Player (PlayerName "Zed")))
        control  <- RPC.registerParticipantChecked ownerId controlTid
          (Individual (Player (PlayerName "Alice")))
        pure (rejected, control)
      case setup of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (rejected, control) -> do
          rejected `shouldBe` Left (RPC.ParticipantKindNotAllowed SquadOnly)
          control  `shouldSatisfy` isRight
      -- control row must exist, proving the db persists across runs...
      aliceLookup <- runSQLiteM testDbPath (Repo.getPlayer (PlayerName "Alice"))
      case aliceLookup of
        Left err -> expectationFailure ("control player missing: " ++ show err)
        Right _  -> pure ()
      -- ...so the rejected player's absence is meaningful.
      zedLookup <- runSQLiteM testDbPath (Repo.getPlayer (PlayerName "Zed"))
      case zedLookup of
        Left _  -> pure ()
        Right _ -> expectationFailure "player row was saved despite rejection"

    it "rejects a Squad in an IndividualOnly tournament and registers nothing" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "rpc-owner-mode-squad"
        tid <- createOpenTournament ownerId "Individual Only Cup" 4
        mapM_ Repo.savePlayer (teamMembers modeTestTeam)
        Repo.saveTeam modeTestTeam
        outcome <- RPC.registerParticipantChecked ownerId tid (Squad modeTestTeam)
        regs <- Repo.listRegistrations tid
        pure (outcome, length regs)
      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, count) -> do
          outcome `shouldBe` Left (RPC.ParticipantKindNotAllowed IndividualOnly)
          count   `shouldBe` 0

    it "accepts a Squad in a SquadOnly tournament" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "rpc-owner-mode-ok"
        tid <- createOpenTournamentWithMode ownerId "Squad Accept Cup" 4 SquadOnly
        mapM_ Repo.savePlayer (teamMembers modeTestTeam)
        Repo.saveTeam modeTestTeam
        outcome <- RPC.registerParticipantChecked ownerId tid (Squad modeTestTeam)
        regs <- Repo.listRegistrations tid
        pure (outcome, length regs)
      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, count) -> do
          outcome `shouldSatisfy` isRight
          count   `shouldBe` 1
    it "finds a team regardless of casing and returns the name as stored" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        mapM_ Repo.savePlayer (teamMembers modeTestTeam)
        Repo.saveTeam modeTestTeam
        found  <- Repo.getTeam (TeamName "fALCONS")
        exists <- Repo.teamExists (TeamName "FALCONS")
        pure (teamName found, exists)
      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (name, exists) -> do
          name   `shouldBe` TeamName "Falcons"
          exists `shouldBe` True

    it "treats differently-cased team names as the same participant" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "rpc-owner-case-dup"
        tid <- createOpenTournamentWithMode ownerId "Case Dup Cup" 4 SquadOnly
        mapM_ Repo.savePlayer (teamMembers modeTestTeam)
        Repo.saveTeam modeTestTeam
        t1 <- Repo.getTeam (TeamName "FALCONS")
        t2 <- Repo.getTeam (TeamName "falcons")
        r1 <- RPC.registerParticipantChecked ownerId tid (Squad t1)
        r2 <- RPC.registerParticipantChecked ownerId tid (Squad t2)
        regs <- Repo.listRegistrations tid
        pure (r1, r2, length regs)
      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (r1, r2, count) -> do
          r1    `shouldSatisfy` isRight
          r2    `shouldBe` Left RPC.AlreadyRegistered
          count `shouldBe` 1

    it "refuses to create a team whose name differs only by case" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        let cap = Player (PlayerName "CaseCap")
            mk n = Team { teamName = TeamName n, teamCaptain = cap, teamMembers = [cap] }
        c1 <- CTM.createTeam (mk "Falcons")
        c2 <- CTM.createTeam (mk "FALCONS")
        pure (c1, c2)
      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (c1, c2) -> do
          c1 `shouldBe` Right ()
          c2 `shouldBe` Left (CTM.TeamNameAlreadyExists (TeamName "FALCONS"))
    it "rejects a non-owner and registers nothing" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId    <- createTestUser "rpc-owner-auth"
        impostorId <- createTestUser "rpc-impostor"
        tid <- createOpenTournament ownerId "RPC Ownership Cup" 4
        outcome <- RPC.registerParticipantChecked impostorId tid
          (Individual (Player (PlayerName "Alice")))
        regs <- Repo.listRegistrations tid
        pure (outcome, length regs)
      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, count) -> do
          outcome `shouldBe` Left (RPC.Unauthorized NotTournamentOwner)
          count   `shouldBe` 0

    it "rejects a blank player name and registers nothing" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "rpc-owner-blank"
        tid <- createOpenTournament ownerId "RPC Blank Cup" 4
        outcome <- RPC.registerParticipantChecked ownerId tid
          (Individual (Player (PlayerName "   ")))
        regs <- Repo.listRegistrations tid
        pure (outcome, length regs)
      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, count) -> do
          outcome `shouldBe` Left (RPC.InvalidParticipant TV.BlankPlayerName)
          count   `shouldBe` 0

    it "rejects registration once MaxParticipants is reached" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "rpc-owner-cap"
        tid <- createOpenTournament ownerId "RPC Capacity Cup" 2
        _ <- unwrap =<< RPC.registerParticipantChecked ownerId tid
               (Individual (Player (PlayerName "Alice")))
        _ <- unwrap =<< RPC.registerParticipantChecked ownerId tid
               (Individual (Player (PlayerName "Bob")))
        outcome <- RPC.registerParticipantChecked ownerId tid
          (Individual (Player (PlayerName "Carol")))
        regs <- Repo.listRegistrations tid
        pure (outcome, length regs)
      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, count) -> do
          outcome `shouldBe` Left RPC.CapacityReached
          count   `shouldBe` 2

    it "rejects registration when the tournament isn't RegistrationOpen" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "rpc-owner-draft"
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "RPC Draft Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
          }
        RPC.registerParticipantChecked ownerId tid
          (Individual (Player (PlayerName "Alice")))
      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldBe`
          Left (RPC.InvalidLifecycle (InvalidTransition Draft RegistrationOpen))

  describe "LoginUser account status" $ do

    it "lets an Active user log in" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        _ <- unwrap =<< RU.registerUser
               (RU.RegisterUserRequest (Username "loginactive") (Email "loginactive@test.com") "password123")
        LU.loginUser (LU.LoginUserRequest (Username "loginactive") "password123")
      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldSatisfy` isRight

    it "rejects a Suspended user who gives the correct password" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        u <- unwrap =<< RU.registerUser
               (RU.RegisterUserRequest (Username "loginsusp") (Email "loginsusp@test.com") "password123")
        Repo.updateAccountStatus (userId u) Suspended
        LU.loginUser (LU.LoginUserRequest (Username "loginsusp") "password123")
      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (Left e)  -> e `shouldBe` LU.AccountNotActive Suspended
        Right (Right _) -> expectationFailure "expected suspended login to be rejected"

    it "does not reveal a suspension when the password is wrong" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        u <- unwrap =<< RU.registerUser
               (RU.RegisterUserRequest (Username "loginprobe") (Email "loginprobe@test.com") "password123")
        Repo.updateAccountStatus (userId u) Suspended
        LU.loginUser (LU.LoginUserRequest (Username "loginprobe") "wrongpass")
      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (Left e)  -> e `shouldBe` LU.InvalidCredentials
        Right (Right _) -> expectationFailure "expected wrong password to be rejected"

  
  describe "LoginUser by email (v0.12)" $ do

    it "lets a user log in with their email address" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        _ <- unwrap =<< RU.registerUser
               (RU.RegisterUserRequest (Username "loginmail") (Email "loginmail@test.com") "password123")
        LU.loginUser (LU.LoginUserRequest (Username "loginmail@test.com") "password123")
      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldSatisfy` isRight

    it "matches the email regardless of letter case" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        _ <- unwrap =<< RU.registerUser
               (RU.RegisterUserRequest (Username "logincase") (Email "logincase@test.com") "password123")
        LU.loginUser (LU.LoginUserRequest (Username "LoginCase@Test.com") "password123")
      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldSatisfy` isRight

    it "rejects an unknown email with InvalidCredentials" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        LU.loginUser (LU.LoginUserRequest (Username "nobody@test.com") "password123")
      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (Left e)  -> e `shouldBe` LU.InvalidCredentials
        Right (Right _) -> expectationFailure "expected unknown email to be rejected"

    it "rejects a Suspended user who logs in by email with the correct password" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        u <- unwrap =<< RU.registerUser
               (RU.RegisterUserRequest (Username "loginmailsusp") (Email "loginmailsusp@test.com") "password123")
        Repo.updateAccountStatus (userId u) Suspended
        LU.loginUser (LU.LoginUserRequest (Username "loginmailsusp@test.com") "password123")
      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (Left e)  -> e `shouldBe` LU.AccountNotActive Suspended
        Right (Right _) -> expectationFailure "expected suspended login to be rejected"

  describe "Self-registration (v0.12)" $ do

    it "lets a signed-in user join, and the view and list show it" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "jn-owner-1"
        joiner <- createTestUser "jn-joiner-1"
        tid <- jnOpen owner "Join Cup" 8 Public
        r <- RPC.joinTournament joiner tid
        v <- GetT.getTournament (Just joiner) tid
        ids <- Repo.listRegisteredTournamentIds joiner
        pure (r, fmap GetT.tvViewerIsRegistered v, ids, tid)
      case result of
        Left err -> expectationFailure (show err)
        Right (r, flag, ids, tid) -> do
          r `shouldSatisfy` isRight
          flag `shouldBe` Right True
          ids `shouldBe` [tid]

    it "rejects a second join by the same account" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "jn-owner-2"
        joiner <- createTestUser "jn-joiner-2"
        tid <- jnOpen owner "Twice Cup" 8 Public
        _ <- unwrap =<< RPC.joinTournament joiner tid
        RPC.joinTournament joiner tid
      case result of
        Left err -> expectationFailure (show err)
        Right r  -> r `shouldBe` Left RPC.JoinAlreadyJoined

    it "rejects a join once the tournament is full" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "jn-owner-3"
        a <- createTestUser "jn-a-3"
        b <- createTestUser "jn-b-3"
        c <- createTestUser "jn-c-3"
        tid <- jnOpen owner "Full Cup" 2 Public
        _ <- unwrap =<< RPC.joinTournament a tid
        _ <- unwrap =<< RPC.joinTournament b tid
        RPC.joinTournament c tid
      case result of
        Left err -> expectationFailure (show err)
        Right r  -> r `shouldBe` Left RPC.JoinFull

    it "rejects a join when registration is not open" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "jn-owner-4"
        joiner <- createTestUser "jn-joiner-4"
        tid <- dtCreate owner "Not Open Cup" noDetails
        Repo.updateTournamentVisibility tid Public
        _ <- unwrap =<< publishTournament owner tid
        RPC.joinTournament joiner tid
      case result of
        Left err -> expectationFailure (show err)
        Right r  -> r `shouldBe` Left (RPC.JoinLifecycle (InvalidTransition Published RegistrationOpen))

    it "does not let a stranger join a Private tournament" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "jn-owner-5"
        joiner <- createTestUser "jn-joiner-5"
        tid <- jnOpen owner "Private Cup" 8 Private
        RPC.joinTournament joiner tid
      case result of
        Left err -> expectationFailure (show err)
        Right (Left (RPC.JoinNotVisible _)) -> pure ()
        Right other -> expectationFailure ("expected JoinNotVisible, got " ++ show other)

    it "reports a name clash with a player the organizer already added" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "jn-owner-6"
        tid <- jnOpen owner "Clash Cup" 8 Public
        _ <- unwrap =<< RPC.registerParticipantChecked owner tid
               (Individual (Player (PlayerName "jn-clash")))
        clasher <- createTestUser "jn-clash"
        RPC.joinTournament clasher tid
      case result of
        Left err -> expectationFailure (show err)
        Right r  -> r `shouldBe` Left RPC.JoinNameTaken

    it "Require approval: create stores the flag, and only the owner can toggle it" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "ra-owner-1"
        other <- createTestUser "ra-other-1"
        tid <- jnOpen owner "Approval Cup" 8 Public
        t0 <- Repo.getTournament tid
        a <- UTRA.updateTournamentRequireApproval other tid True
        b <- UTRA.updateTournamentRequireApproval owner tid True
        t1 <- Repo.getTournament tid
        c <- UTRA.updateTournamentRequireApproval owner tid False
        t2 <- Repo.getTournament tid
        tid2 <- unwrap =<< CreateApproval.createTournamentWithApproval (raNew owner "Approval Create Cup") noDetails True
        t3 <- Repo.getTournament tid2
        tid3 <- unwrap =<< CreateApproval.createTournamentWithApproval (raNew owner "Open Create Cup") noDetails False
        t4 <- Repo.getTournament tid3
        pure ( tournamentRequireApproval t0, raTag a, raTag b, tournamentRequireApproval t1
             , raTag c, tournamentRequireApproval t2, tournamentRequireApproval t3, tournamentRequireApproval t4 )
      result `shouldBe` Right (False, "unauthorized", "ok", True, "ok", False, True, False)

    it "Join requests: approving registers the player, declining removes them, and a decline can be reversed" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "ap-owner-1"
        a <- createTestUser "ap-a-1"
        tid <- jnOpen owner "Approve Cup" 8 Public
        _ <- unwrap =<< UTRA.updateTournamentRequireApproval owner tid True
        _ <- JRQ.joinOrRequest a tid
        r1 <- JRQ.approveJoinRequest owner tid a
        regs1 <- length <$> Repo.listRegistrations tid
        s1 <- Repo.getJoinRequest tid a
        d1 <- JRQ.declineJoinRequest owner tid a
        regs2 <- length <$> Repo.listRegistrations tid
        s2 <- Repo.getJoinRequest tid a
        r2 <- JRQ.approveJoinRequest owner tid a
        regs3 <- length <$> Repo.listRegistrations tid
        pure (apTag r1, regs1, s1, dcTag d1, regs2, s2, apTag r2, regs3)
      result `shouldBe` Right ("ok", 1, Just JoinApproved, "ok", 0, Just JoinDeclined, "ok", 1)

    it "Join requests: only the owner can approve or decline, and approval respects capacity" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "ap-owner-2"
        a <- createTestUser "ap-a-2"
        b <- createTestUser "ap-b-2"
        c <- createTestUser "ap-c-2"
        tid <- jnOpen owner "Capacity Approve Cup" 2 Public
        _ <- unwrap =<< UTRA.updateTournamentRequireApproval owner tid True
        _ <- JRQ.joinOrRequest a tid
        _ <- JRQ.joinOrRequest b tid
        _ <- JRQ.joinOrRequest c tid
        x <- JRQ.approveJoinRequest a tid b
        y <- JRQ.declineJoinRequest a tid b
        ra <- JRQ.approveJoinRequest owner tid a
        rb <- JRQ.approveJoinRequest owner tid b
        rc <- JRQ.approveJoinRequest owner tid c
        pure (apTag x, dcTag y, apTag ra, apTag rb, apTag rc)
      result `shouldBe` Right ("unauthorized", "unauthorized", "ok", "ok", "full")

    it "Notifications: join requests notify the organizer, approve and decline notify the player, and read clears the count" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "nt-owner-1"
        a <- createTestUser "nt-a-1"
        b <- createTestUser "nt-b-1"
        tid <- jnOpen owner "Notify Cup" 8 Public
        _ <- unwrap =<< UTRA.updateTournamentRequireApproval owner tid True
        _ <- JRQ.joinOrRequest a tid
        _ <- JRQ.joinOrRequest b tid
        ownerNotes <- Repo.listNotifications owner 20
        _ <- unwrap =<< JRQ.approveJoinRequest owner tid a
        _ <- unwrap =<< JRQ.declineJoinRequest owner tid b
        aNotes <- Repo.listNotifications a 20
        bNotes <- Repo.listNotifications b 20
        unread1 <- Repo.countUnreadNotifications a
        Repo.markAllNotificationsRead a
        unread2 <- Repo.countUnreadNotifications a
        pure ( map Notif.notificationKind ownerNotes, map Notif.notificationKind aNotes
             , map Notif.notificationKind bNotes, unread1, unread2 )
      result `shouldBe` Right
        ( [Notif.NoteJoinRequested, Notif.NoteJoinRequested]
        , [Notif.NoteRequestApproved], [Notif.NoteRequestDeclined], 1, 0 )

    it "Notifications: registered account ids are listed, typed-in players have no account" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "nt-owner-2"
        a <- createTestUser "nt-a-2"
        tid <- jnOpen owner "Account Ids Cup" 8 Public
        _ <- JRQ.joinOrRequest a tid
        _ <- unwrap =<< RPC.registerParticipantChecked owner tid (Individual (Player (PlayerName "nt-typed")))
        ids <- Repo.listRegisteredUserIds tid
        pure (ids == [a])
      result `shouldBe` Right True

    it "Rankings: titles rank before wins, and a title does not replace the wins" $ do
      Rk.computeRankings [(Just (rkP "ann"), [rkP "ann", rkP "ann", rkP "bob"]), (Nothing, [rkP "bob"])]
        `shouldBe` [Rk.RankingEntry "ann" 1 2, Rk.RankingEntry "bob" 0 2]

    it "Rankings: equal titles and wins are ordered by name" $ do
      Rk.computeRankings [(Nothing, [rkP "zed", rkP "amy"])]
        `shouldBe` [Rk.RankingEntry "amy" 0 1, Rk.RankingEntry "zed" 0 1]

    it "Rankings: a tournament without a bracket contributes nothing" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "rk-owner-1"
        _ <- jnOpen owner "Rank Empty Cup" 8 Public
        GRK.getRankings 5
      result `shouldBe` Right []

    it "Recent activity: lists public events newest first, never private or draft tournaments" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "act-owner-1"
        _ <- jnOpen owner "Act Public Cup" 8 Public
        _ <- jnOpen owner "Act Private Cup" 8 Private
        _ <- dtCreate owner "Act Draft Cup" noDetails
        items <- Repo.recentPublicActivity 10
        pure (map (\i -> (ActH.activityTournamentName i, ActH.activityEvent i)) items)
      result `shouldBe` Right [("Act Public Cup", ActH.RegistrationOpened), ("Act Public Cup", ActH.TournamentPublished)]

    it "Recent activity: the limit applies" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "act-owner-2"
        _ <- jnOpen owner "Act Cap A" 8 Public
        _ <- jnOpen owner "Act Cap B" 8 Public
        _ <- jnOpen owner "Act Cap C" 8 Public
        three <- length <$> Repo.recentPublicActivity 3
        everything <- length <$> Repo.recentPublicActivity 50
        pure (three, everything)
      result `shouldBe` Right (3, 6)

    it "Join requests: with approval off, joining registers immediately as before" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "jr-owner-0"
        joiner <- createTestUser "jr-joiner-0"
        tid <- jnOpen owner "Open Join Cup" 8 Public
        r <- JRQ.joinOrRequest joiner tid
        regs <- length <$> Repo.listRegistrations tid
        req <- Repo.getJoinRequest tid joiner
        pure (jrTag r, regs, req)
      result `shouldBe` Right ("joined", 1, Nothing)

    it "Join requests: with approval on, joining creates a pending request, not a registration" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "jr-owner-1"
        joiner <- createTestUser "jr-joiner-1"
        tid <- jnOpen owner "Request Cup" 8 Public
        _ <- unwrap =<< UTRA.updateTournamentRequireApproval owner tid True
        r1 <- JRQ.joinOrRequest joiner tid
        regs <- length <$> Repo.listRegistrations tid
        r2 <- JRQ.joinOrRequest joiner tid
        st <- Repo.getJoinRequest tid joiner
        pure (jrTag r1, regs, jrTag r2, st)
      result `shouldBe` Right ("pending", 0, "already-pending", Just JoinPending)

    it "Join requests: a declined request cannot be repeated, and a pending one can be cancelled" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "jr-owner-2"
        a <- createTestUser "jr-a-2"
        b <- createTestUser "jr-b-2"
        tid <- jnOpen owner "Decline Cup" 8 Public
        _ <- unwrap =<< UTRA.updateTournamentRequireApproval owner tid True
        _ <- JRQ.joinOrRequest a tid
        Repo.saveJoinRequest tid a JoinDeclined
        ra <- JRQ.joinOrRequest a tid
        _ <- JRQ.joinOrRequest b tid
        c1 <- JRQ.cancelJoinRequest b tid
        c2 <- JRQ.cancelJoinRequest b tid
        sb <- Repo.getJoinRequest tid b
        pure (jrTag ra, cqTag c1, cqTag c2, sb)
      result `shouldBe` Right ("declined", "ok", "none", Nothing)

    it "Organizer removes a participant: on an approval tournament a self-registered player is declined, a typed-in one is plainly removed" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "rd-owner-1"
        a <- createTestUser "rd-a-1"
        tid <- jnOpen owner "Remove Decline Cup" 8 Public
        _ <- unwrap =<< UTRA.updateTournamentRequireApproval owner tid True
        _ <- JRQ.joinOrRequest a tid
        _ <- unwrap =<< JRQ.approveJoinRequest owner tid a
        let pa    = Individual (Player (PlayerName "rd-a-1"))
            typed = Individual (Player (PlayerName "rd-typed"))
        _ <- unwrap =<< RPC.registerParticipantChecked owner tid typed
        r1 <- RPC.removeParticipant owner tid pa
        s1 <- Repo.getJoinRequest tid a
        again <- JRQ.joinOrRequest a tid
        r2 <- RPC.removeParticipant owner tid typed
        regs <- length <$> Repo.listRegistrations tid
        pure (rmTag r1, s1, jrTag again, rmTag r2, regs)
      result `shouldBe` Right ("ok", Just JoinDeclined, "declined", "ok", 0)

    it "Organizer removes a participant: on an open tournament a removed self-registered player can join again" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "rd-owner-2"
        a <- createTestUser "rd-a-2"
        tid <- jnOpen owner "Remove Open Cup" 8 Public
        _ <- JRQ.joinOrRequest a tid
        r1 <- RPC.removeParticipant owner tid (Individual (Player (PlayerName "rd-a-2")))
        s1 <- Repo.getJoinRequest tid a
        again <- JRQ.joinOrRequest a tid
        pure (rmTag r1, s1, jrTag again)
      result `shouldBe` Right ("ok", Nothing, "joined")

    it "Organizer removes a participant: removes, and the player can register again" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "rm-owner-1"
        tid <- jnOpen owner "Remove Cup" 8 Public
        let p = Individual (Player (PlayerName "rm-fresco"))
        _ <- unwrap =<< RPC.registerParticipantChecked owner tid p
        before <- length <$> Repo.listRegistrations tid
        r1 <- RPC.removeParticipant owner tid p
        after <- length <$> Repo.listRegistrations tid
        _ <- unwrap =<< RPC.registerParticipantChecked owner tid p
        again <- length <$> Repo.listRegistrations tid
        pure (before, rmTag r1, after, again)
      result `shouldBe` Right (1, "ok", 0, 1)

    it "Organizer removes a participant: rejects non-owner, not-registered and wrong state" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "rm-owner-2"
        other <- createTestUser "rm-other-2"
        tid <- jnOpen owner "Remove Guard Cup" 8 Public
        draftTid <- dtCreate owner "Remove Draft Cup" noDetails
        let p = Individual (Player (PlayerName "rm-guard"))
        _ <- unwrap =<< RPC.registerParticipantChecked owner tid p
        a <- RPC.removeParticipant other tid p
        b <- RPC.removeParticipant owner tid (Individual (Player (PlayerName "rm-nobody")))
        c <- RPC.removeParticipant owner draftTid p
        left <- length <$> Repo.listRegistrations tid
        pure (rmTag a, rmTag b, rmTag c, left)
      result `shouldBe` Right ("unauthorized", "not-registered", "lifecycle", 1)

    it "withdraws while registration is open, and rejects a second withdraw" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "jn-owner-7"
        joiner <- createTestUser "jn-joiner-7"
        tid <- jnOpen owner "Withdraw Cup" 8 Public
        _ <- unwrap =<< RPC.joinTournament joiner tid
        w1 <- RPC.withdrawFromTournament joiner tid
        ids <- Repo.listRegisteredTournamentIds joiner
        w2 <- RPC.withdrawFromTournament joiner tid
        pure (w1, ids, w2)
      case result of
        Left err -> expectationFailure (show err)
        Right (w1, ids, w2) -> do
          w1 `shouldBe` Right ()
          ids `shouldBe` []
          w2 `shouldBe` Left RPC.WithdrawNotRegistered

    it "lets the organizer join their own tournament" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "jn-owner-8"
        tid <- jnOpen owner "Own Cup" 8 Public
        RPC.joinTournament owner tid
      case result of
        Left err -> expectationFailure (show err)
        Right r  -> r `shouldSatisfy` isRight

  describe "Self-registration squad-only (v0.12)" $ do

    it "rejects a join in a SquadOnly tournament" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "jn-owner-9"
        joiner <- createTestUser "jn-joiner-9"
        tid <- unwrap =<< CTD.createTournamentWithDetails
                 ((dtNew owner "Squad Join Cup") { newTournamentParticipantMode = SquadOnly }) noDetails
        _ <- unwrap =<< publishTournament owner tid
        _ <- unwrap =<< openRegistration owner tid
        RPC.joinTournament joiner tid
      case result of
        Left err -> expectationFailure (show err)
        Right r  -> r `shouldBe` Left RPC.JoinSquadOnly

  describe "Full name (v0.12)" $ do

    it "trims a valid name, treats blank as none, and rejects one over 60 characters" $ do
      EU.validateFullName "  Jae Kim  " `shouldBe` Right (Just "Jae Kim")
      EU.validateFullName "   " `shouldBe` Right Nothing
      EU.validateFullName "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" `shouldBe` Left EU.FullNameTooLong

    it "stores, reads back and clears a full name" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        uid <- createTestUser "fn-user-1"
        a <- Repo.getFullName uid
        Repo.setFullName uid (Just "Jae Kim")
        b <- Repo.getFullName uid
        Repo.setFullName uid Nothing
        c <- Repo.getFullName uid
        pure (a, b, c)
      case result of
        Left err -> expectationFailure (show err)
        Right r  -> r `shouldBe` (Nothing, Just "Jae Kim", Nothing)

  describe "Password reset storage (v0.12)" $ do

    it "stores a reset, finds it, and consumes all of a user's resets" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        uid <- createTestUser "pr-user-1"
        rid <- Repo.createPasswordReset uid "hash-1" 2000000000
        a <- Repo.findPasswordReset rid
        Repo.consumePasswordResets uid
        b <- Repo.findPasswordReset rid
        pure (uid, rid, a, b)
      case result of
        Left err -> expectationFailure (show err)
        Right (uid, rid, a, b) -> do
          rid `shouldSatisfy` (> 0)
          a `shouldBe` Just (uid, "hash-1", 2000000000, False)
          b `shouldBe` Just (uid, "hash-1", 2000000000, True)

    it "returns Nothing for an unknown reset id" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        Repo.findPasswordReset 999999
      case result of
        Left err -> expectationFailure (show err)
        Right r  -> r `shouldBe` Nothing

  describe "Registration deadline (v0.12)" $ do

    it "stores the deadline through the details update and logs one history entry" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "dl-owner-1"
        tid <- dtCreate owner "Deadline Cup" noDetails
        r <- UTD.updateTournamentDetails owner tid (noDetails { detailsRegistrationDeadline = Just dtTime })
        t <- Repo.getTournament tid
        changed <- dtChanged tid
        pure (r, tournamentRegistrationDeadline t, changed)
      case result of
        Left err -> expectationFailure (show err)
        Right (r, dl, changed) -> do
          r `shouldBe` Right ()
          dl `shouldBe` Just dtTime
          changed `shouldBe` [TournamentHistory.FieldRegistrationDeadline]

    it "rejects a deadline after the start time" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "dl-owner-2"
        tid <- dtCreate owner "Late Deadline Cup" noDetails
        UTD.updateTournamentDetails owner tid
          (noDetails { detailsStartTime = Just dtTime
                     , detailsRegistrationDeadline = Just (UTCTime (fromGregorian 2026 12 13) 64800) })
      case result of
        Left err -> expectationFailure (show err)
        Right (Left (UTD.InvalidDetails _)) -> pure ()
        Right other -> expectationFailure ("expected InvalidDetails, got " ++ show other)

    it "refuses a join after the deadline and allows one before it" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "dl-owner-3"
        early <- createTestUser "dl-early-3"
        late <- createTestUser "dl-late-3"
        tid <- jnOpen owner "Deadline Join Cup" 8 Public
        Repo.updateTournamentDetails tid (noDetails { detailsRegistrationDeadline = Just dtTime })
        a <- JRQ.joinOrRequestAt (UTCTime (fromGregorian 2026 12 1) 0) early tid
        b <- JRQ.joinOrRequestAt (UTCTime (fromGregorian 2026 12 20) 0) late tid
        pure (a, b)
      case result of
        Left err -> expectationFailure (show err)
        Right (a, b) -> do
          a `shouldSatisfy` isRight
          b `shouldBe` Left JRQ.JoinDeadlinePassed

  describe "Team self-registration (v0.12)" $ do

    it "lets a team's owner register it, and it shows in their list" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "st-owner-1"
        cap <- createTestUser "st-cap-1"
        stMake cap "st-team-1"
        tid <- stOpen owner "Team Join Cup" 8
        r <- RPC.joinTournamentAsTeam stNow cap tid "st-team-1"
        ids <- Repo.listRegisteredTournamentIds cap
        pure (r, ids, tid)
      case result of
        Left err -> expectationFailure (show err)
        Right (r, ids, tid) -> do
          r `shouldSatisfy` isRight
          ids `shouldBe` [tid]

    it "rejects someone who does not own the team" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "st-owner-2"
        cap <- createTestUser "st-cap-2"
        thief <- createTestUser "st-thief-2"
        stMake cap "st-team-2"
        tid <- stOpen owner "Not Yours Cup" 8
        RPC.joinTournamentAsTeam stNow thief tid "st-team-2"
      case result of
        Left err -> expectationFailure (show err)
        Right r  -> r `shouldBe` Left RPC.JoinTeamNotOwner

    it "rejects a team that has no owner" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "st-owner-3"
        someone <- createTestUser "st-someone-3"
        _ <- unwrap =<< createTeam (stTeam "st-team-3")
        tid <- stOpen owner "Unowned Cup" 8
        RPC.joinTournamentAsTeam stNow someone tid "st-team-3"
      case result of
        Left err -> expectationFailure (show err)
        Right r  -> r `shouldBe` Left RPC.JoinTeamNotOwner

    it "rejects a second registration by the same account" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "st-owner-4"
        cap <- createTestUser "st-cap-4"
        stMake cap "st-team-4a"
        stMake cap "st-team-4b"
        tid <- stOpen owner "Twice Cup" 8
        _ <- unwrap =<< RPC.joinTournamentAsTeam stNow cap tid "st-team-4a"
        RPC.joinTournamentAsTeam stNow cap tid "st-team-4b"
      case result of
        Left err -> expectationFailure (show err)
        Right r  -> r `shouldBe` Left RPC.JoinTeamAlreadyJoined

    it "rejects a join in an individual tournament, and when approval is required" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "st-owner-5"
        cap <- createTestUser "st-cap-5"
        stMake cap "st-team-5"
        solo <- jnOpen owner "Solo Cup" 8 Public
        a <- RPC.joinTournamentAsTeam stNow cap solo "st-team-5"
        tid <- stOpen owner "Approval Squad Cup" 8
        Repo.updateTournamentRequireApproval tid True
        b <- RPC.joinTournamentAsTeam stNow cap tid "st-team-5"
        pure (a, b)
      case result of
        Left err -> expectationFailure (show err)
        Right (a, b) -> do
          a `shouldBe` Left RPC.JoinTeamIndividualOnly
          b `shouldBe` Left RPC.JoinTeamApprovalRequired

    it "rejects a join once the tournament is full" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "st-owner-6"
        c1 <- createTestUser "st-cap-6a"
        c2 <- createTestUser "st-cap-6b"
        c3 <- createTestUser "st-cap-6c"
        stMake c1 "st-team-6a"
        stMake c2 "st-team-6b"
        stMake c3 "st-team-6c"
        tid <- stOpen owner "Full Squad Cup" 2
        _ <- unwrap =<< RPC.joinTournamentAsTeam stNow c1 tid "st-team-6a"
        _ <- unwrap =<< RPC.joinTournamentAsTeam stNow c2 tid "st-team-6b"
        RPC.joinTournamentAsTeam stNow c3 tid "st-team-6c"
      case result of
        Left err -> expectationFailure (show err)
        Right r  -> r `shouldBe` Left RPC.JoinTeamFull

    it "rejects a join after the registration deadline" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        owner <- createTestUser "st-owner-7"
        cap <- createTestUser "st-cap-7"
        stMake cap "st-team-7"
        tid <- stOpen owner "Late Squad Cup" 8
        Repo.updateTournamentDetails tid (noDetails { detailsRegistrationDeadline = Just dtTime })
        RPC.joinTournamentAsTeam (UTCTime (fromGregorian 2027 1 1) 0) cap tid "st-team-7"
      case result of
        Left err -> expectationFailure (show err)
        Right r  -> r `shouldBe` Left RPC.JoinTeamDeadlinePassed

  describe "Engine.User.validateRawPassword (pure)" $ do

    it "rejects a password shorter than 8 characters" $
      EU.validateRawPassword "1234567" `shouldBe` Left EU.PasswordTooShort

    it "accepts exactly 8 characters" $
      EU.validateRawPassword "12345678" `shouldBe` Right "12345678"

  describe "GetTournament (read)" $ do

    it "shows the owner their tournament with its participants" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "gt-owner"
        tid <- createOpenTournament ownerId "GT Owner Cup" 4
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
        _ <- unwrap =<< RPC.registerParticipantChecked ownerId tid alice
        _ <- unwrap =<< RPC.registerParticipantChecked ownerId tid bob
        outcome <- GetT.getTournament (Just ownerId) tid
        pure (outcome, alice, bob)
      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (Left e, _, _) -> expectationFailure (show e)
        Right (Right v, alice, bob) -> do
          GetT.tvParticipants v `shouldMatchList` [alice, bob]
          GetT.tvViewerIsOwner v `shouldBe` True
          tournamentName (GetT.tvTournament v) `shouldBe` TournamentName "GT Owner Cup"

    it "lets any authenticated caller view a Public tournament, without owner rights" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId    <- createTestUser "gt-owner-pub"
        strangerId <- createTestUser "gt-stranger-pub"
        tid <- createOpenTournament ownerId "GT Public Cup" 4
        GetT.getTournament (Just strangerId) tid
      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (Left e) -> expectationFailure (show e)
        Right (Right v) -> GetT.tvViewerIsOwner v `shouldBe` False

    it "rejects a non-owner viewing a Private tournament" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId    <- createTestUser "gt-owner-priv"
        strangerId <- createTestUser "gt-stranger-priv"
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "GT Private Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Private
          , newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
          }
        GetT.getTournament (Just strangerId) tid
      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldBe` Left (GetT.Unauthorized NotAuthorizedToView)

  describe "ListMyTournaments" $

    it "returns only the caller's tournaments" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        a <- createTestUser "lm-a"
        b <- createTestUser "lm-b"
        _ <- createOpenTournament a "LM A1" 4
        _ <- createOpenTournament a "LM A2" 4
        _ <- createOpenTournament b "LM B1" 4
        ListMine.listMyTournaments a
      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right ts -> map tournamentName ts `shouldMatchList`
                      [TournamentName "LM A1", TournamentName "LM A2"]

  describe "CancelTournament blank reason" $

    it "rejects a whitespace-only cancellation reason and leaves the state alone" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "cancel-blank-owner"
        tid <- createOpenTournament ownerId "Cancel Blank Cup" 4
        outcome <- cancelTournament ownerId tid "   "
        after   <- Repo.getTournament tid
        pure (outcome, tournamentState after)
      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, st) -> do
          outcome `shouldBe` Left CancelT.EmptyCancellationReason
          st      `shouldBe` RegistrationOpen

  describe "requireVisibleToViewer (pure)" $ do
    let mk st vis = Tournament
          { tournamentId = TournamentId 1, tournamentName = TournamentName "x"
          , tournamentOrganizer = OrganizerName "x", tournamentFormat = SingleElimination
          , tournamentState = st, tournamentVisibility = vis
          , tournamentMaxParticipants = 2, tournamentBracket = Nothing
          , tournamentOwner = UserId 1, tournamentThirdPlaceMatch = False, tournamentParticipantMode = IndividualOnly, tournamentGame = Nothing, tournamentStartTime = Nothing, tournamentPrize = Nothing, tournamentDescription = Nothing, tournamentRequireApproval = False, tournamentRegistrationDeadline = Nothing }
        owner    = Just (UserId 1)
        stranger = Just (UserId 2)

    it "shows a Public non-Draft tournament to anyone, including anonymous" $ do
      requireVisibleToViewer Nothing  (mk Published Public) `shouldBe` Right ()
      requireVisibleToViewer stranger (mk Published Public) `shouldBe` Right ()

    it "hides a Draft from everyone but the owner, even when Public" $ do
      requireVisibleToViewer Nothing  (mk Draft Public) `shouldBe` Left NotAuthorizedToView
      requireVisibleToViewer stranger (mk Draft Public) `shouldBe` Left NotAuthorizedToView
      requireVisibleToViewer owner    (mk Draft Public) `shouldBe` Right ()

    it "hides a Private tournament from everyone but the owner" $ do
      requireVisibleToViewer Nothing  (mk Published Private) `shouldBe` Left NotAuthorizedToView
      requireVisibleToViewer stranger (mk Published Private) `shouldBe` Left NotAuthorizedToView
      requireVisibleToViewer owner    (mk Published Private) `shouldBe` Right ()

  describe "GetTournament anonymous viewers" $ do

    it "lets an anonymous viewer see a Public tournament once it is past Draft" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "gt-owner-anon"
        tid <- createOpenTournament ownerId "GT Anonymous Cup" 4
        GetT.getTournament Nothing tid
      case result of
        Left err       -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (Left e) -> expectationFailure (show e)
        Right (Right v) -> GetT.tvViewerIsOwner v `shouldBe` False

    it "hides a Public Draft from an anonymous viewer" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "gt-owner-draft"
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "GT Draft Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
          }
        GetT.getTournament Nothing tid
      case result of
        Left err    -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner -> inner `shouldBe` Left (GetT.Unauthorized NotAuthorizedToView)

  describe "ListPublicTournaments (pure selection)" $ do
    let mk i st vis = Tournament
          { tournamentId = TournamentId i, tournamentName = TournamentName "x"
          , tournamentOrganizer = OrganizerName "x", tournamentFormat = SingleElimination
          , tournamentState = st, tournamentVisibility = vis
          , tournamentMaxParticipants = 2, tournamentBracket = Nothing
          , tournamentOwner = UserId 1, tournamentThirdPlaceMatch = False, tournamentParticipantMode = IndividualOnly, tournamentGame = Nothing, tournamentStartTime = Nothing, tournamentPrize = Nothing, tournamentDescription = Nothing, tournamentRequireApproval = False, tournamentRegistrationDeadline = Nothing }
        ids = map (unTournamentId . tournamentId)

    it "keeps only Public tournaments past Draft, newest first" $
      ids (LP.selectPublic 10
            [ mk 1 Published Public, mk 2 Draft Public
            , mk 3 Published Private, mk 4 Completed Public ])
        `shouldBe` [4, 1]

    it "caps the result at the limit" $
      ids (LP.selectPublic 2 [ mk i Published Public | i <- [1 .. 5] ])
        `shouldBe` [5, 4]

  describe "Third-Place (Bronze) Match (v0.11)" $ do

    it "SE without third-place match: unaffected baseline (4 players, bronze match never exists)" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "tp-baseline-owner"
        let participants@[alice,bob,carol,dave] =
              [ Individual (Player (PlayerName n)) | n <- ["Alice","Bob","Carol","Dave"] ]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "TP Baseline Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        (bracket, _) <- Repo.getBracket bracketId

        let playWinner p ms = do
              let m = head (filter (\x -> matchCompetitorA x == p || matchCompetitorB x == p) ms)
              _ <- unwrap =<< startMatch ownerId (matchId m)
              _ <- unwrap =<< recordMatchResult ownerId (matchId m) (Winner p)
              pure ()

        semis <- Repo.listMatchesForBracket bracketId
        liftIO $ length semis `shouldBe` 2
        playWinner alice semis
        playWinner carol semis

        afterSemis <- Repo.listMatchesForBracket bracketId
        liftIO $ length afterSemis `shouldBe` 3   -- 2 semis + final; no bronze match, ever
        let final = head (filter (\m -> matchStatus m == Scheduled) afterSemis)
        playWinner alice [final]

        _ <- unwrap =<< startTournament ownerId tid
        completion <- completeTournament ownerId tid
        finalCount <- length <$> Repo.listMatchesForBracket bracketId
        pure (bracket, completion, finalCount)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (bracket, completion, finalCount) -> do
          bracketThirdPlaceNodeId bracket `shouldBe` Nothing
          completion `shouldSatisfy` isRight
          finalCount `shouldBe` 3

    it "SE with third-place match enabled (4 players): node exists at generation, bronze match materializes once both semis complete, correct competitors, records a result normally" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "tp-4p-owner"
        let participants@[alice,bob,carol,dave] =
              [ Individual (Player (PlayerName n)) | n <- ["Alice","Bob","Carol","Dave"] ]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "TP Four Player Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = True
          , newTournamentParticipantMode = IndividualOnly
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        (bracket, _) <- Repo.getBracket bracketId

        let playWinner p ms = do
              let m = head (filter (\x -> matchCompetitorA x == p || matchCompetitorB x == p) ms)
              _ <- unwrap =<< startMatch ownerId (matchId m)
              _ <- unwrap =<< recordMatchResult ownerId (matchId m) (Winner p)
              pure ()

        semis <- Repo.listMatchesForBracket bracketId
        liftIO $ length semis `shouldBe` 2
        -- Alice beats Bob, Carol beats Dave -- Bob and Dave, the two
        -- semifinal losers, should meet in the bronze match.
        playWinner alice semis
        playWinner carol semis

        afterSemis <- Repo.listMatchesForBracket bracketId
        liftIO $ length afterSemis `shouldBe` 4   -- final + bronze both materialize together

        let Just tpNodeId = bracketThirdPlaceNodeId bracket
            bronzeMatch = head (filter (\m -> matchBracketNode m == tpNodeId) afterSemis)

        liftIO $ [matchCompetitorA bronzeMatch, matchCompetitorB bronzeMatch]
          `shouldMatchList` [bob, dave]

        -- Bronze match records a result exactly like any other match.
        _ <- unwrap =<< startMatch ownerId (matchId bronzeMatch)
        _ <- unwrap =<< recordMatchResult ownerId (matchId bronzeMatch) (Winner bob)
        bronzeAfter <- Repo.getMatch (matchId bronzeMatch)

        pure (bronzeAfter, bob)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (bronzeAfter, bob) -> do
          matchStatus bronzeAfter `shouldBe` Match.Completed
          matchOutcome bronzeAfter `shouldBe` Just (Winner bob)

    it "correcting a semifinal also corrects the final's bracket slot, not just the match record" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "corr-slot-owner"
        let participants@[alice,bob,carol,dave] =
              [ Individual (Player (PlayerName n)) | n <- ["Alice","Bob","Carol","Dave"] ]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Correction Slot Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        let findMatchOf p ms = head (filter (\x -> matchCompetitorA x == p || matchCompetitorB x == p) ms)
            playWinner p ms = do
              let m = findMatchOf p ms
              _ <- unwrap =<< startMatch ownerId (matchId m)
              _ <- unwrap =<< recordMatchResult ownerId (matchId m) (Winner p)
              pure ()
        semis <- Repo.listMatchesForBracket bracketId
        playWinner alice semis
        let semi1 = findMatchOf alice semis
        _ <- unwrap =<< correctMatchResult ownerId (matchId semi1) (Winner bob)
        (_, nodes) <- Repo.getBracket bracketId
        let finalNode = head (filter ((== 2) . nodeRound) nodes)
        playWinner carol semis
        afterAll <- Repo.listMatchesForBracket bracketId
        let finalMatch = head (filter (\m -> matchBracketNode m == nodeId finalNode) afterAll)
        pure ( [nodeSlotA finalNode, nodeSlotB finalNode]
             , [matchCompetitorA finalMatch, matchCompetitorB finalMatch]
             , alice, bob, carol )

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (slots, finalCompetitors, alice, bob, carol) -> do
          (Filled bob `elem` slots) `shouldBe` True
          (Filled alice `elem` slots) `shouldBe` False
          finalCompetitors `shouldMatchList` [bob, carol]

    it "correcting a semifinal with a third-place match moves both the final and the bronze match" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "corr-bronze-owner"
        let participants@[alice,bob,carol,dave] =
              [ Individual (Player (PlayerName n)) | n <- ["Alice","Bob","Carol","Dave"] ]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Correction Bronze Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = True
          , newTournamentParticipantMode = IndividualOnly
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        let findMatchOf p ms = head (filter (\x -> matchCompetitorA x == p || matchCompetitorB x == p) ms)
            playWinner p ms = do
              let m = findMatchOf p ms
              _ <- unwrap =<< startMatch ownerId (matchId m)
              _ <- unwrap =<< recordMatchResult ownerId (matchId m) (Winner p)
              pure ()
        semis <- Repo.listMatchesForBracket bracketId
        playWinner alice semis
        playWinner carol semis
        let semi1 = findMatchOf alice semis
        _ <- unwrap =<< correctMatchResult ownerId (matchId semi1) (Winner bob)
        (bracket, nodes) <- Repo.getBracket bracketId
        afterFix <- Repo.listMatchesForBracket bracketId
        let Just tpNodeId = bracketThirdPlaceNodeId bracket
            finalNodeId = nodeId (head (filter (\n -> nodeRound n == 2 && nodeId n /= tpNodeId) nodes))
            bronze = head (filter (\m -> matchBracketNode m == tpNodeId) afterFix)
            finalM = head (filter (\m -> matchBracketNode m == finalNodeId) afterFix)
        pure ( [matchCompetitorA finalM, matchCompetitorB finalM]
             , [matchCompetitorA bronze, matchCompetitorB bronze]
             , alice, bob, carol, dave )

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (finalCompetitors, bronzeCompetitors, alice, bob, carol, dave) -> do
          finalCompetitors  `shouldMatchList` [bob, carol]
          bronzeCompetitors `shouldMatchList` [alice, dave]
    it "bronze match does not materialize until both semis complete" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "tp-timing-owner"
        let participants@[alice,bob,carol,dave] =
              [ Individual (Player (PlayerName n)) | n <- ["Alice","Bob","Carol","Dave"] ]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "TP Timing Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = True
          , newTournamentParticipantMode = IndividualOnly
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

        semis <- Repo.listMatchesForBracket bracketId
        playWinner alice semis

        afterOneSemi <- Repo.listMatchesForBracket bracketId
        let countAfterOneSemi = length afterOneSemi

        playWinner carol semis

        afterBothSemis <- Repo.listMatchesForBracket bracketId
        pure (countAfterOneSemi, length afterBothSemis)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (countAfterOneSemi, countAfterBothSemis) -> do
          countAfterOneSemi   `shouldBe` 2   -- only the 2 semis exist; one still Scheduled
          countAfterBothSemis `shouldBe` 4   -- final + bronze materialize together, once both semis are Completed

    it "final completed before the bronze match: completion rejected until bronze is also Completed" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "tp-order-final-first-owner"
        let participants@[alice,bob,carol,dave] =
              [ Individual (Player (PlayerName n)) | n <- ["Alice","Bob","Carol","Dave"] ]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "TP Final First Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = True
          , newTournamentParticipantMode = IndividualOnly
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

        semis <- Repo.listMatchesForBracket bracketId
        playWinner alice semis
        playWinner carol semis

        afterSemis <- Repo.listMatchesForBracket bracketId
        let scheduled = filter (\m -> matchStatus m == Scheduled) afterSemis
        liftIO $ length scheduled `shouldBe` 2   -- final + bronze

        playWinner alice scheduled   -- final only (Alice v Carol)

        _ <- unwrap =<< startTournament ownerId tid
        tooEarly <- completeTournament ownerId tid

        afterFinal <- Repo.listMatchesForBracket bracketId
        let bronzeMatch = head (filter (\m -> matchStatus m == Scheduled) afterFinal)
        _ <- unwrap =<< startMatch ownerId (matchId bronzeMatch)
        _ <- unwrap =<< recordMatchResult ownerId (matchId bronzeMatch) (Winner (matchCompetitorA bronzeMatch))

        completion <- completeTournament ownerId tid
        pure (tooEarly, completion)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (tooEarly, completion) -> do
          tooEarly   `shouldBe` Left (CT.InvalidCompletion TournamentNotComplete)
          completion `shouldSatisfy` isRight

    it "bronze match completed before the final: completion rejected until final is also Completed" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "tp-order-bronze-first-owner"
        let participants@[alice,bob,carol,dave] =
              [ Individual (Player (PlayerName n)) | n <- ["Alice","Bob","Carol","Dave"] ]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "TP Bronze First Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = True
          , newTournamentParticipantMode = IndividualOnly
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

        semis <- Repo.listMatchesForBracket bracketId
        playWinner alice semis
        playWinner carol semis

        afterSemis <- Repo.listMatchesForBracket bracketId
        let scheduled = filter (\m -> matchStatus m == Scheduled) afterSemis
        playWinner bob scheduled   -- bronze only (Bob v Dave)

        tooEarly <- completeTournament ownerId tid

        afterBronze <- Repo.listMatchesForBracket bracketId
        let finalMatch = head (filter (\m -> matchStatus m == Scheduled) afterBronze)
        _ <- unwrap =<< startMatch ownerId (matchId finalMatch)
        _ <- unwrap =<< recordMatchResult ownerId (matchId finalMatch) (Winner (matchCompetitorA finalMatch))

        _ <- unwrap =<< startTournament ownerId tid
        completion <- completeTournament ownerId tid
        pure (tooEarly, completion)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (tooEarly, completion) -> do
          tooEarly   `shouldBe` Left (CT.InvalidCompletion TournamentNotComplete)
          completion `shouldSatisfy` isRight

    it "rejects DoubleElimination with thirdPlaceMatch = True at creation" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "tp-de-reject-owner"
        outcome <- CTU.createTournamentChecked NewTournament
          { newTournamentName            = TournamentName "TP DE Reject Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = DoubleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = True
          , newTournamentParticipantMode = IndividualOnly
          }
        stored <- Repo.listAllTournaments
        pure (outcome, length stored)
      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, count) -> do
          outcome `shouldBe` Left (CTU.InvalidTournament TV.ThirdPlaceMatchRequiresSingleElimination)
          count `shouldBe` 0

    it "rejects RoundRobin with thirdPlaceMatch = True at creation" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "tp-rr-reject-owner"
        outcome <- CTU.createTournamentChecked NewTournament
          { newTournamentName            = TournamentName "TP RR Reject Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = RoundRobin
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 3
          , newTournamentThirdPlaceMatch = True
          , newTournamentParticipantMode = IndividualOnly
          }
        stored <- Repo.listAllTournaments
        pure (outcome, length stored)
      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, count) -> do
          outcome `shouldBe` Left (CTU.InvalidTournament TV.ThirdPlaceMatchRequiresSingleElimination)
          count `shouldBe` 0

    it "3-player bracket: bye-shaped semifinal suppresses the bronze match entirely, even with the option enabled" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "tp-3p-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            carol = Individual (Player (PlayerName "Carol"))
            participants = [alice, bob, carol]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "TP Three Player Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 3
          , newTournamentThirdPlaceMatch = True
          , newTournamentParticipantMode = IndividualOnly
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        (bracket, _) <- Repo.getBracket bracketId

        semiMatches <- Repo.listMatchesForBracket bracketId
        liftIO $ length semiMatches `shouldBe` 1   -- Alice's bye
        let semiMatch = head semiMatches
        _ <- unwrap =<< startMatch ownerId (matchId semiMatch)
        _ <- unwrap =<< recordMatchResult ownerId (matchId semiMatch) (Winner (matchCompetitorB semiMatch))

        allMatches <- Repo.listMatchesForBracket bracketId
        let finalMatch = head (filter (\m -> matchStatus m == Scheduled) allMatches)
        _ <- unwrap =<< startMatch ownerId (matchId finalMatch)
        _ <- unwrap =<< recordMatchResult ownerId (matchId finalMatch) (Winner (matchCompetitorA finalMatch))

        _ <- unwrap =<< startTournament ownerId tid
        completion <- completeTournament ownerId tid
        finalCount <- length <$> Repo.listMatchesForBracket bracketId
        pure (bracket, completion, finalCount)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (bracket, completion, finalCount) -> do
          bracketThirdPlaceNodeId bracket `shouldBe` Nothing
          completion `shouldSatisfy` isRight
          finalCount `shouldBe` 2

    it "rejects changing format to DoubleElimination while thirdPlaceMatch = True" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "tp-format-change-owner"
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "TP Format Change Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = True
          , newTournamentParticipantMode = IndividualOnly
          }
        outcome <- updateTournamentFormat ownerId tid DoubleElimination
        after   <- Repo.getTournament tid
        pure (outcome, tournamentFormat after)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, formatAfter) -> do
          outcome     `shouldBe` Left (UTF.InvalidTournament TV.ThirdPlaceMatchRequiresSingleElimination)
          formatAfter `shouldBe` SingleElimination   -- rejected, nothing persisted

    it "rejects a format change once the bracket exists" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "format-after-bracket-owner"
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Format After Bracket Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          , newTournamentThirdPlaceMatch = False
          , newTournamentParticipantMode = IndividualOnly
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        _ <- unwrap =<< generateBracket ownerId tid
        outcome <- updateTournamentFormat ownerId tid DoubleElimination
        after   <- Repo.getTournament tid
        pure (outcome, tournamentFormat after)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, formatAfter) -> do
          outcome     `shouldBe` Left UTF.BracketAlreadyGenerated
          formatAfter `shouldBe` SingleElimination
    it "disabling thirdPlaceMatch before bracket generation: no bronze match materializes, normal SE completion" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "tp-disable-owner"
        let participants@[alice,bob,carol,dave] =
              [ Individual (Player (PlayerName n)) | n <- ["Alice","Bob","Carol","Dave"] ]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "TP Disable Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = True
          , newTournamentParticipantMode = IndividualOnly
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)

        -- Disable while still RegistrationOpen (before RegistrationClosed,
        -- per the locked design's "editable pre-RegistrationClosed" rule).
        _ <- unwrap =<< updateTournamentThirdPlaceMatch ownerId tid False

        _ <- unwrap =<< closeRegistration ownerId tid
        bracketId <- unwrap =<< generateBracket ownerId tid
        (bracket, _) <- Repo.getBracket bracketId

        let playWinner p ms = do
              let m = head (filter (\x -> matchCompetitorA x == p || matchCompetitorB x == p) ms)
              _ <- unwrap =<< startMatch ownerId (matchId m)
              _ <- unwrap =<< recordMatchResult ownerId (matchId m) (Winner p)
              pure ()

        semis <- Repo.listMatchesForBracket bracketId
        playWinner alice semis
        playWinner carol semis

        afterSemis <- Repo.listMatchesForBracket bracketId
        let scheduled = filter (\m -> matchStatus m == Scheduled) afterSemis
        liftIO $ length scheduled `shouldBe` 1   -- final only -- no bronze match to wait on
        playWinner alice scheduled

        _ <- unwrap =<< startTournament ownerId tid
        completion <- completeTournament ownerId tid
        pure (bracket, completion)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (bracket, completion) -> do
          bracketThirdPlaceNodeId bracket `shouldBe` Nothing
          completion `shouldSatisfy` isRight

    it "rejects toggling thirdPlaceMatch once the bracket exists" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        ownerId <- createTestUser "tp-toggle-guard-owner"
        let participants = [ Individual (Player (PlayerName n)) | n <- ["Alice","Bob","Carol","Dave"] ]
        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "TP Toggle Guard Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentOwner           = ownerId
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 4
          , newTournamentThirdPlaceMatch = True
          , newTournamentParticipantMode = IndividualOnly
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        advanceToRegistrationOpen ownerId tid
        forM_ participants (\p -> unwrap =<< registerParticipant tid p)
        _ <- unwrap =<< closeRegistration ownerId tid
        _ <- unwrap =<< generateBracket ownerId tid
        outcome <- updateTournamentThirdPlaceMatch ownerId tid False
        after   <- Repo.getTournament tid
        pure (outcome, tournamentThirdPlaceMatch after)

      case result of
        Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right (outcome, flagAfter) -> do
          outcome   `shouldBe` Left UTTP.BracketAlreadyGenerated
          flagAfter `shouldBe` True



-- ---------------------------------------------------------------------
-- Bracket links (step 1): pure derivation only, nothing persisted.
-- ---------------------------------------------------------------------

blId :: Int -> BLIds.BracketNodeId
blId = BLIds.BracketNodeId

blN :: Int -> BLBr.MatchSlot -> BLBr.MatchSlot -> Int -> BLBr.BracketNode
blN i a b r = BLBr.BracketNode (blId i) a b r BLBr.Winners

blDest :: Int -> BLLin.SlotPosition -> BLLin.NodeDestination
blDest i pos = BLLin.NodeDestination (blId i) pos

blTag :: String -> Int -> String
blTag what players = what ++ ", " ++ show players ++ " players: "

blPlayers n = [ Individual (Player (PlayerName ("bl" ++ show i))) | i <- [1 .. n :: Int] ]

blSe :: Int -> [BLBr.BracketNode]
blSe players = BLGen.buildTopology (BLGen.bracketSize players)

blDerive :: [BLBr.BracketNode] -> BLLin.BracketLinks
blDerive nodes = case BLEng.deriveLinks nodes of
    Right links -> links
    Left err    -> error ("deriveLinks failed: " ++ show err)

blLinksOf :: BLLin.BracketLinks -> BLBr.BracketNode -> BLLin.NodeLinks
blLinksOf links n = case BLLin.lookupLinks (BLBr.nodeId n) links of
    Just l  -> l
    Nothing -> error ("no links entry for node " ++ show (BLBr.nodeId n))

blWinnerNode :: BLLin.BracketLinks -> BLBr.BracketNode -> Maybe BLIds.BracketNodeId
blWinnerNode links n = BLLin.destNode <$> BLLin.linkWinnerTo (blLinksOf links n)

blLoserNode :: BLLin.BracketLinks -> BLBr.BracketNode -> Maybe BLIds.BracketNodeId
blLoserNode links n = BLLin.destNode <$> BLLin.linkLoserTo (blLinksOf links n)

blNodeById :: BLIds.BracketNodeId -> [BLBr.BracketNode] -> BLBr.BracketNode
blNodeById i nodes = case filter ((== i) . BLBr.nodeId) nodes of
    (n : _) -> n
    []      -> error ("no node " ++ show i)

blSlotAt :: BLLin.SlotPosition -> BLBr.BracketNode -> BLBr.MatchSlot
blSlotAt BLLin.SlotA = BLBr.nodeSlotA
blSlotAt BLLin.SlotB = BLBr.nodeSlotB

blIsPointer :: BLBr.MatchSlot -> Bool
blIsPointer (BLBr.AwaitingWinnerOf _) = True
blIsPointer (BLBr.AwaitingLoserOf _)  = True
blIsPointer _                         = False

-- Every destination must be backed by a real pointer (right node, right slot,
-- right pointer kind), and every pointer in the graph must be accounted for.
blConsistent :: [BLBr.BracketNode] -> BLLin.BracketLinks -> Bool
blConsistent nodes links = backed && length dests == pointerCount
  where
    dests =
        [ (isWinner, src, d)
        | (src, l) <- links
        , (isWinner, Just d) <- [(True, BLLin.linkWinnerTo l), (False, BLLin.linkLoserTo l)]
        ]
    slotOf d = fmap (blSlotAt (BLLin.destSlot d)) (lookup (BLLin.destNode d) [ (BLBr.nodeId n, n) | n <- nodes ])
    expected isWinner src = if isWinner then BLBr.AwaitingWinnerOf src else BLBr.AwaitingLoserOf src
    backed = all (\(w, src, d) -> slotOf d == Just (expected w src)) dests
    pointerCount = length [ () | n <- nodes, s <- [BLBr.nodeSlotA n, BLBr.nodeSlotB n], blIsPointer s ]

blFinalOf :: [BLBr.BracketNode] -> BLBr.BracketNode
blFinalOf = foldr1 (\a b -> if BLBr.nodeRound a >= BLBr.nodeRound b then a else b)

blMaxRound :: [BLBr.BracketNode] -> Int
blMaxRound nodes = maximum (map BLBr.nodeRound nodes)

blThird :: Int -> ([BLBr.BracketNode], BLIds.BracketNodeId)
blThird players = case BLGen.addThirdPlaceMatch (blSe players) of
    (nodes, Just tp) -> (nodes, tp)
    (_, Nothing)     -> error "no third-place node was added"

-- loser destinations, ordered slot A first, then slot B
blLoserDests :: [BLBr.BracketNode] -> [BLLin.NodeDestination]
blLoserDests nodes =
    [ d
    | pos <- [BLLin.SlotA, BLLin.SlotB]
    , n <- nodes
    , Just d <- [BLLin.linkLoserTo (blLinksOf links n)]
    , BLLin.destSlot d == pos
    ]
  where links = blDerive nodes

blLoserSourceIds :: [BLBr.BracketNode] -> [Int]
blLoserSourceIds nodes =
    BLList.sort [ BLIds.unBracketNodeId (BLBr.nodeId n) | n <- nodes, BLLin.linkLoserTo (blLinksOf links n) /= Nothing ]
  where links = blDerive nodes

blSemiIds :: [BLBr.BracketNode] -> [Int]
blSemiIds nodes =
    BLList.sort [ BLIds.unBracketNodeId (BLBr.nodeId n) | n <- nodes, BLBr.nodeRound n == blMaxRound nodes - 1 ]

-- double elimination as generated: seeded winners bracket, then losers bracket, grand final, reset
blDe :: Int -> ([BLBr.BracketNode], [BLBr.BracketNode], BLIds.BracketNodeId, BLIds.BracketNodeId)
blDe players = (wb, wb ++ other, gf1, reset)
  where
    size = BLGen.bracketSize players
    wb = BLSeed.seedParticipants (blPlayers players) (BLGen.buildTopology size)
    (other, gf1, reset) = BLGen.buildDoubleEliminationTopology wb size

blSeSpec :: Int -> Spec
blSeSpec players = do
    it (blTag "single elimination" players ++ "every destination is backed by a real pointer and every pointer is accounted for") $
        blConsistent topo links `shouldBe` True
    it (blTag "single elimination" players ++ "exactly one node (the final) has no winner destination") $
        length [ () | n <- topo, blWinnerNode links n == Nothing ] `shouldBe` 1
    it (blTag "single elimination" players ++ "no node has a loser destination") $
        length [ () | n <- topo, BLLin.linkLoserTo (blLinksOf links n) /= Nothing ] `shouldBe` 0
    it (blTag "single elimination" players ++ "winner destination equals findParent on the template") $
        [ BLBr.nodeId n | n <- topo, blWinnerNode links n /= BLGen.findParent (BLBr.nodeId n) topo ] `shouldBe` []
  where
    topo  = blSe players
    links = blDerive topo

blSeRound1Spec :: Int -> Spec
blSeRound1Spec players =
    it (blTag "single elimination" players ++ "every round-1 node has a winner destination") $
        [ BLBr.nodeId n | n <- topo, BLBr.nodeRound n == 1, blWinnerNode links n == Nothing ] `shouldBe` []
  where
    topo  = blSe players
    links = blDerive topo

-- The caller must derive from the graph before bye resolution. Derived from the
-- seeded graph every node but the final has a winner destination; derived after
-- bye resolution has consumed pointers, links are missing.
blPrePostSpec :: Int -> Spec
blPrePostSpec players = do
    it (blTag "single elimination, seeded, before bye resolution" players ++ "only the final lacks a winner destination") $
        length [ () | n <- seeded, blWinnerNode preLinks n == Nothing ] `shouldBe` 1
    it (blTag "single elimination, after bye resolution" players ++ "links are lost, which is why the pre-resolution graph is required") $
        length [ () | n <- resolved, blWinnerNode postLinks n == Nothing ] `shouldSatisfy` (> 1)
  where
    seeded    = BLSeed.seedParticipants (blPlayers players) (blSe players)
    resolved  = BLBye.resolveAutomaticAdvancements seeded
    preLinks  = blDerive seeded
    postLinks = blDerive resolved

blThirdSpec :: Int -> Spec
blThirdSpec players = do
    it (blTag "with third place" players ++ "every destination is backed by a real pointer and every pointer is accounted for") $
        blConsistent nodes links `shouldBe` True
    it (blTag "with third place" players ++ "loser destinations are the third-place node, slot A then slot B") $
        blLoserDests nodes `shouldBe` [BLLin.NodeDestination tp BLLin.SlotA, BLLin.NodeDestination tp BLLin.SlotB]
    it (blTag "with third place" players ++ "only the two semifinals have a loser destination") $
        blLoserSourceIds nodes `shouldBe` blSemiIds nodes
    it (blTag "with third place" players ++ "semifinal winners do not go to the third-place node") $
        [ BLBr.nodeId n | n <- nodes, BLBr.nodeRound n == blMaxRound nodes - 1, blWinnerNode links n == Just tp ] `shouldBe` []
    it (blTag "with third place" players ++ "the third-place node has no destinations") $
        blLinksOf links (blNodeById tp nodes) `shouldBe` BLLin.NodeLinks Nothing Nothing
    it (blTag "with third place" players ++ "exactly the final and the third-place node have no winner destination") $
        length [ () | n <- nodes, blWinnerNode links n == Nothing ] `shouldBe` 2
  where
    (nodes, tp) = blThird players
    links = blDerive nodes

-- full = bracket size equals player count (no byes). The lineage oracles are
-- one-directional: wherever the existing helper resolves a destination, the
-- derived link must agree; where the helper declines, nothing is asserted.
blDeSpec :: Bool -> Int -> Spec
blDeSpec full players = do
    it (tag ++ "every destination is backed by a real pointer and every pointer is accounted for") $
        blConsistent allNodes links `shouldBe` True
    it (tag ++ "grand final winner and loser feed the reset match, slots A and B") $
        blLinksOf links (blNodeById gf1 allNodes)
            `shouldBe` BLLin.NodeLinks (Just (BLLin.NodeDestination reset BLLin.SlotA)) (Just (BLLin.NodeDestination reset BLLin.SlotB))
    it (tag ++ "the reset match has no destinations") $
        blLinksOf links (blNodeById reset allNodes) `shouldBe` BLLin.NodeLinks Nothing Nothing
    it (tag ++ "the winners-bracket final feeds the grand final, slot A") $
        BLLin.linkWinnerTo (blLinksOf links wbFinal) `shouldBe` Just (BLLin.NodeDestination gf1 BLLin.SlotA)
    it (tag ++ "the losers-bracket final feeds the grand final, slot B") $
        BLLin.linkWinnerTo (blLinksOf links lbFinal) `shouldBe` Just (BLLin.NodeDestination gf1 BLLin.SlotB)
    it (tag ++ "no losers-bracket node has a loser destination") $
        length [ () | n <- lbNodes, BLLin.linkLoserTo (blLinksOf links n) /= Nothing ] `shouldBe` 0
    it (tag ++ "winners-bracket winner destinations agree with resolveWBWinnerTarget wherever it resolves") $
        [ BLBr.nodeId n
        | n <- wb
        , Just t <- [BLLD.resolveWBWinnerTarget size (BLBr.nodeId n)]
        , blWinnerNode links n /= Just t ] `shouldBe` []
    it (tag ++ "winners-bracket loser destinations agree with resolveWBLoserTarget wherever it resolves") $
        [ BLBr.nodeId n
        | n <- wb
        , Right t <- [BLLD.resolveWBLoserTarget wb size (BLBr.nodeId n)]
        , blLoserNode links n /= Just t ] `shouldBe` []
    it (tag ++ "losers-bracket winner destinations agree with resolveLBTarget wherever it resolves") $
        [ BLBr.nodeId n
        | n <- lbNodes
        , Just t <- [BLLD.resolveLBTarget wb size (BLBr.nodeId n)]
        , blWinnerNode links n /= Just t ] `shouldBe` []
    BLM.when full $ do
        it (tag ++ "only the reset match lacks a winner destination") $
            [ BLBr.nodeId n | n <- allNodes, blWinnerNode links n == Nothing ] `shouldBe` [reset]
        it (tag ++ "every winners-bracket node has a loser destination") $
            [ BLBr.nodeId n | n <- wb, blLoserNode links n == Nothing ] `shouldBe` []
  where
    tag = blTag (if full then "full double elimination" else "double elimination with byes") players
    size = BLGen.bracketSize players
    (wb, allNodes, gf1, reset) = blDe players
    links = blDerive allNodes
    wbFinal = blFinalOf wb
    lbNodes = filter ((== BLBr.Losers) . BLBr.nodeStage) allNodes
    lbFinal = last lbNodes

blErrorSpec :: Spec
blErrorSpec = do
    it "an empty node list yields no links" $
        BLEng.deriveLinks [] `shouldBe` Right []
    it "a pointer to a node that is not in the graph is rejected" $
        BLEng.deriveLinks [blN 1 (BLBr.AwaitingWinnerOf (blId 99)) BLBr.ByeSlot 2]
            `shouldBe` Left (BLEng.DanglingPointer (blId 1) (blId 99))
    it "two nodes claiming the winner of the same node are rejected" $
        BLEng.deriveLinks
            [ blN 1 BLBr.ByeSlot BLBr.ByeSlot 1
            , blN 2 (BLBr.AwaitingWinnerOf (blId 1)) BLBr.ByeSlot 2
            , blN 3 (BLBr.AwaitingWinnerOf (blId 1)) BLBr.ByeSlot 2
            ]
            `shouldBe` Left (BLEng.ConflictingWinnerDestination (blId 1) (blDest 2 BLLin.SlotA) (blDest 3 BLLin.SlotA))
    it "two nodes claiming the loser of the same node are rejected" $
        BLEng.deriveLinks
            [ blN 1 BLBr.ByeSlot BLBr.ByeSlot 1
            , blN 2 (BLBr.AwaitingLoserOf (blId 1)) BLBr.ByeSlot 2
            , blN 3 BLBr.ByeSlot (BLBr.AwaitingLoserOf (blId 1)) 2
            ]
            `shouldBe` Left (BLEng.ConflictingLoserDestination (blId 1) (blDest 2 BLLin.SlotA) (blDest 3 BLLin.SlotB))
    it "duplicate node ids are rejected" $
        BLEng.deriveLinks [blN 1 BLBr.ByeSlot BLBr.ByeSlot 1, blN 1 BLBr.ByeSlot BLBr.ByeSlot 1]
            `shouldBe` Left (BLEng.DuplicateNodeId (blId 1))
    it "winner and loser destinations of the same node are independent and may coexist" $
        BLEng.deriveLinks
            [ blN 1 BLBr.ByeSlot BLBr.ByeSlot 1
            , blN 2 (BLBr.AwaitingWinnerOf (blId 1)) BLBr.ByeSlot 2
            , blN 3 (BLBr.AwaitingLoserOf (blId 1)) BLBr.ByeSlot 2
            ]
            `shouldBe` Right
                [ (blId 1, BLLin.NodeLinks (Just (blDest 2 BLLin.SlotA)) (Just (blDest 3 BLLin.SlotA)))
                , (blId 2, BLLin.NodeLinks Nothing Nothing)
                , (blId 3, BLLin.NodeLinks Nothing Nothing)
                ]
    it "a pointer already replaced (as bye resolution does) contributes no link" $
        BLEng.deriveLinks
            [ blN 1 BLBr.ByeSlot BLBr.ByeSlot 1
            , blN 2 BLBr.ByeSlot BLBr.ByeSlot 1
            , blN 3 (BLBr.AwaitingWinnerOf (blId 1)) BLBr.ByeSlot 2
            ]
            `shouldBe` Right
                [ (blId 1, BLLin.NodeLinks (Just (blDest 3 BLLin.SlotA)) Nothing)
                , (blId 2, BLLin.NodeLinks Nothing Nothing)
                , (blId 3, BLLin.NodeLinks Nothing Nothing)
                ]

bracketLinksSpec :: Spec
bracketLinksSpec = describe "Engine.BracketLinks.deriveLinks" $ do
    mapM_ blSeSpec [2, 3, 4, 5, 8, 20]
    mapM_ blSeRound1Spec [3, 4, 5, 8, 20]
    mapM_ blPrePostSpec [3, 5, 6, 7, 20]
    mapM_ blThirdSpec [4, 8, 20]
    mapM_ (blDeSpec True) [4, 8, 16]
    mapM_ (blDeSpec False) [5, 6, 7]
    blErrorSpec

-- ---------------------------------------------------------------------
-- Bracket links (step 2): persistence. Stored node ids are deliberately
-- offset from domain ids by saving a throwaway bracket first.
-- ---------------------------------------------------------------------

bsTournament :: Text -> SQLiteM TournamentId
bsTournament label = do
  ownerId <- createTestUser label
  Repo.createTournament NewTournament
    { newTournamentName            = TournamentName "bs links"
    , newTournamentOrganizer       = OrganizerName "Test Organizer"
    , newTournamentOwner           = ownerId
    , newTournamentFormat          = SingleElimination
    , newTournamentVisibility      = Public
    , newTournamentMaxParticipants = 8
    , newTournamentThirdPlaceMatch = False
    , newTournamentParticipantMode = IndividualOnly
    }

bsTemplate :: [BLBr.BracketNode]
bsTemplate = BLGen.buildTopology 8

bsLinks :: BLLin.BracketLinks
bsLinks = blDerive bsTemplate

bsBracket :: TournamentId -> BLIds.BracketId -> BLBr.Bracket
bsBracket tid bid = BLBr.Bracket
  { BLBr.bracketId = bid
  , BLBr.bracketTournament = tid
  , BLBr.bracketGF1NodeId = Nothing
  , BLBr.bracketResetNodeId = Nothing
  , BLBr.bracketThirdPlaceNodeId = Nothing
  }

bsSave :: TournamentId -> SQLiteM (BLIds.BracketId, BLMap.Map BLIds.BracketNodeId BLIds.BracketNodeId)
bsSave tid = do
  bid <- Repo.createBracket tid
  idMap <- Repo.saveBracket (bsBracket tid bid) bsTemplate
  pure (bid, idMap)

-- domain-keyed links translated into stored ids, ordered by stored id
bsTranslate :: BLMap.Map BLIds.BracketNodeId BLIds.BracketNodeId -> BLLin.BracketLinks -> BLLin.BracketLinks
bsTranslate idMap links = BLList.sortOn fst
  [ (at k, BLLin.NodeLinks (dest <$> BLLin.linkWinnerTo l) (dest <$> BLLin.linkLoserTo l)) | (k, l) <- links ]
  where
    at k = idMap BLMap.! k
    dest d = d { BLLin.destNode = at (BLLin.destNode d) }

bsExpectStorageFailure :: Show a => Either PersistenceError a -> Expectation
bsExpectStorageFailure (Left (StorageFailure _)) = pure ()
bsExpectStorageFailure other = expectationFailure ("expected StorageFailure, got: " ++ show other)

bsExpectNothing :: Show a => Either PersistenceError (Maybe a) -> Expectation
bsExpectNothing (Right Nothing) = pure ()
bsExpectNothing other = expectationFailure ("expected Right Nothing, got: " ++ show other)

bsUnknownDest :: BLLin.BracketLinks
bsUnknownDest =
  [ (k, if k == blId 1 then l { BLLin.linkWinnerTo = Just (BLLin.NodeDestination (blId 99) BLLin.SlotA) } else l)
  | (k, l) <- bsLinks ]

bsDuplicate :: BLLin.BracketLinks
bsDuplicate = take (length bsLinks - 1) bsLinks ++ take 1 bsLinks

bsRejectsSpec :: String -> BLLin.BracketLinks -> Spec
bsRejectsSpec label bad =
  it ("saving links that " ++ label ++ " is rejected and writes nothing") $ do
    setup <- runSQLiteM testDbPath $ do
      setupSchema
      tid <- bsTournament "bs-owner"
      bsSave tid
    case setup of
      Left err -> expectationFailure (show err)
      Right (bid, idMap) -> do
        rejected <- runSQLiteM testDbPath (Repo.saveBracketLinks bid idMap bad)
        bsExpectStorageFailure rejected
        after <- runSQLiteM testDbPath (Repo.getBracketLinks bid)
        bsExpectNothing after

bracketLinksStoreSpec :: Spec
bracketLinksStoreSpec = describe "BracketRepository bracket links (offset ids)" $ do
  it "round trip with offset ids: links are keyed by stored ids and agree with the stored pointers" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      throwawayTid <- bsTournament "bs-owner-1"
      targetTid <- bsTournament "bs-owner-2"
      (throwawayBid, _) <- bsSave throwawayTid
      (bid, idMap) <- bsSave targetTid
      Repo.saveBracketLinks bid idMap bsLinks
      stored <- Repo.getBracketLinks bid
      throwawayLinks <- Repo.getBracketLinks throwawayBid
      (_, nodes) <- Repo.getBracket bid
      pure (idMap, stored, throwawayLinks, nodes)
    case result of
      Left err -> expectationFailure (show err)
      Right (idMap, stored, throwawayLinks, nodes) -> do
        [ k | (k, v) <- BLMap.toList idMap, k == v ] `shouldBe` []
        throwawayLinks `shouldBe` Nothing
        stored `shouldBe` Just (bsTranslate idMap bsLinks)
        fmap (blConsistent nodes) stored `shouldBe` Just True
        fmap (map fst) stored `shouldBe` Just (BLList.sort (map BLBr.nodeId nodes))

  it "a bracket with no stored links reads as unavailable" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      tid <- bsTournament "bs-owner"
      (bid, _) <- bsSave tid
      Repo.getBracketLinks bid
    bsExpectNothing result

  it "a missing link row makes the read fail instead of returning a partial set" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      tid <- bsTournament "bs-owner"
      (bid, idMap) <- bsSave tid
      Repo.saveBracketLinks bid idMap bsLinks
      env <- ask
      liftIO $ execute (envConnection env) "DELETE FROM bracket_links WHERE node_id = ?"
        (Only (BLIds.unBracketNodeId (idMap BLMap.! blId 1)))
      Repo.getBracketLinks bid
    bsExpectStorageFailure result

  it "a slot that is not A or B in storage fails the read" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      tid <- bsTournament "bs-owner"
      (bid, idMap) <- bsSave tid
      Repo.saveBracketLinks bid idMap bsLinks
      env <- ask
      let conn = envConnection env
      liftIO $ BLSql.execute_ conn "PRAGMA ignore_check_constraints = ON"
      liftIO $ execute conn "UPDATE bracket_links SET winner_slot = 'Z' WHERE node_id = ?"
        (Only (BLIds.unBracketNodeId (idMap BLMap.! blId 1)))
      liftIO $ BLSql.execute_ conn "PRAGMA ignore_check_constraints = OFF"
      Repo.getBracketLinks bid
    bsExpectStorageFailure result

  it "a destination that belongs to another bracket fails the read" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      tid <- bsTournament "bs-owner"
      (_, otherMap) <- bsSave tid
      (bid, idMap) <- bsSave tid
      Repo.saveBracketLinks bid idMap bsLinks
      env <- ask
      liftIO $ execute (envConnection env)
        "UPDATE bracket_links SET winner_node_id = ?, winner_slot = 'A' WHERE node_id = ?"
        ( BLIds.unBracketNodeId (otherMap BLMap.! blId 1)
        , BLIds.unBracketNodeId (idMap BLMap.! blId 1) )
      Repo.getBracketLinks bid
    bsExpectStorageFailure result

  bsRejectsSpec "miss a node" (drop 1 bsLinks)
  bsRejectsSpec "name a destination that was never saved" bsUnknownDest
  bsRejectsSpec "list a node twice" bsDuplicate

  it "deleting a bracket deletes its links" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      tid <- bsTournament "bs-owner"
      (bid, idMap) <- bsSave tid
      Repo.saveBracketLinks bid idMap bsLinks
      Repo.deleteBracket bid
      Repo.getBracketLinks bid
    bsExpectNothing result

  it "saving a bracket's nodes again clears the links that pointed at the old ones" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      tid <- bsTournament "bs-owner"
      (bid, idMap) <- bsSave tid
      Repo.saveBracketLinks bid idMap bsLinks
      _ <- Repo.saveBracket (bsBracket tid bid) bsTemplate
      Repo.getBracketLinks bid
    bsExpectNothing result

-- ---------------------------------------------------------------------
-- Correction on brackets whose stored node ids are offset from the
-- template ids (buildTopology numbers nodes from 1). Each scenario runs
-- twice: a control on a clean database, and one after a throwaway
-- bracket has used up node ids.
-- ---------------------------------------------------------------------

-- A throwaway bracket in its own tournament: uses up 7 node ids.
crBurnIds :: SQLiteM ()
crBurnIds = do
  tid <- bsTournament "cr-burn"
  _ <- bsSave tid
  pure ()

crSetup :: Bool -> Text -> Int -> SQLiteM (UserId, BLIds.BracketId)
crSetup burn label n = do
  BLM.when burn crBurnIds
  ownerId <- createTestUser label
  let participants =
        [ Individual (Player (PlayerName ("P" ++ show i))) | i <- [1 .. n] ]
  tid <- createTournament NewTournament
    { newTournamentName = TournamentName "Correction node-id cup"
    , newTournamentOrganizer = OrganizerName "Test Organizer"
    , newTournamentOwner = ownerId, newTournamentFormat = SingleElimination
    , newTournamentVisibility = Public, newTournamentMaxParticipants = n
    , newTournamentThirdPlaceMatch = False, newTournamentParticipantMode = IndividualOnly }
  forM_ participants $ \p -> case p of
    Individual player -> Repo.savePlayer player
    Squad team         -> Repo.saveTeam team
  advanceToRegistrationOpen ownerId tid
  forM_ participants (\p -> unwrap =<< registerParticipant tid p)
  _ <- unwrap =<< closeRegistration ownerId tid
  bracketId <- unwrap =<< generateBracket ownerId tid
  (_, nodes) <- Repo.getBracket bracketId
  -- the premise of every example here: stored ids are first-insert (they start at 1) or offset
  liftIO $ (minimum [ BLIds.unBracketNodeId (BLBr.nodeId nd) | nd <- nodes ] == 1) `shouldBe` not burn
  pure (ownerId, bracketId)

-- Both semifinals played, the final started: correcting a semifinal must be rejected.
crGuardSpec :: String -> Bool -> Spec
crGuardSpec title burn =
  it title $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      (ownerId, bracketId) <- crSetup burn "cr-guard-owner" 4
      r1 <- Repo.listMatchesForBracket bracketId
      let [ma, mb] = r1
      _ <- unwrap =<< startMatch ownerId (matchId ma)
      _ <- unwrap =<< recordMatchResult ownerId (matchId ma) (Winner (matchCompetitorA ma))
      _ <- unwrap =<< startMatch ownerId (matchId mb)
      _ <- unwrap =<< recordMatchResult ownerId (matchId mb) (Winner (matchCompetitorA mb))
      allM <- Repo.listMatchesForBracket bracketId
      let finalM = head [ m | m <- allM, matchBracketNode m `notElem` map matchBracketNode r1 ]
      _ <- unwrap =<< startMatch ownerId (matchId finalM)
      outcome <- correctMatchResult ownerId (matchId ma) (Winner (matchCompetitorB ma))
      pure (matchId finalM, either Just (const Nothing) outcome)
    case result of
      Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
      Right (finalId, rejected) ->
        rejected `shouldBe` Just (DownstreamMatchStarted finalId)

-- One match played, the next one still Scheduled: the correction must reach
-- the next node's slot and the next match.
crRepairSpec :: String -> Bool -> Spec
crRepairSpec title burn =
  it title $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      (ownerId, bracketId) <- crSetup burn "cr-repair-owner" 5
      (_, nodesBefore) <- Repo.getBracket bracketId
      let round1NodeIds = map BLBr.nodeId (filter ((== 1) . BLBr.nodeRound) nodesBefore)
      allMatchesAtGen <- Repo.listMatchesForBracket bracketId
      let m1 = head (filter (\m -> matchBracketNode m `elem` round1NodeIds) allMatchesAtGen)
          m1Winner = matchCompetitorA m1
          m1Loser  = matchCompetitorB m1
          -- found from the PRE-PLAY stored pointer, independent of findParent
          downstreamNodeId =
            case find (\nd -> BLBr.nodeSlotA nd == BLBr.AwaitingWinnerOf (matchBracketNode m1)
                           || BLBr.nodeSlotB nd == BLBr.AwaitingWinnerOf (matchBracketNode m1)) nodesBefore of
              Just nd -> BLBr.nodeId nd
              Nothing -> error "test setup invariant violated: m1 has no parent node"
      _ <- unwrap =<< startMatch ownerId (matchId m1)
      _ <- unwrap =<< recordMatchResult ownerId (matchId m1) (Winner m1Winner)
      afterM1 <- Repo.listMatchesForBracket bracketId
      let down0 = head (filter (\m -> matchBracketNode m == downstreamNodeId) afterM1)
          setupOk = matchCompetitorA down0 == m1Winner || matchCompetitorB down0 == m1Winner
      corrected <- unwrap =<< correctMatchResult ownerId (matchId m1) (Winner m1Loser)
      afterMatches <- Repo.listMatchesForBracket bracketId
      (_, nodesAfter) <- Repo.getBracket bracketId
      let downstream = head (filter (\m -> matchBracketNode m == downstreamNodeId) afterMatches)
          downstreamNode = head (filter ((== downstreamNodeId) . BLBr.nodeId) nodesAfter)
      pure (setupOk, corrected, downstream, downstreamNode, m1Winner, m1Loser)
    case result of
      Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
      Right (setupOk, corrected, downstream, downstreamNode, m1Winner, m1Loser) -> do
        setupOk `shouldBe` True
        matchOutcome corrected `shouldBe` Just (Winner m1Loser)
        (matchCompetitorA downstream == m1Winner || matchCompetitorB downstream == m1Winner) `shouldBe` False
        (matchCompetitorA downstream == m1Loser || matchCompetitorB downstream == m1Loser) `shouldBe` True
        (BLBr.nodeSlotA downstreamNode == BLBr.Filled m1Winner || BLBr.nodeSlotB downstreamNode == BLBr.Filled m1Winner) `shouldBe` False
        (BLBr.nodeSlotA downstreamNode == BLBr.Filled m1Loser || BLBr.nodeSlotB downstreamNode == BLBr.Filled m1Loser) `shouldBe` True

correctionNodeIdSpec :: Spec
correctionNodeIdSpec = describe "NodeIdSpace: CorrectMatchResult (Single Elim)" $ do
  crGuardSpec  "guard, control (first-insert ids): rejects with DownstreamMatchStarted once the next match has started" False
  crGuardSpec  "guard, offset ids: rejects with DownstreamMatchStarted once the next match has started" True
  crRepairSpec "repair, control (first-insert ids): the next match and node take the corrected winner" False
  crRepairSpec "repair, offset ids: the next match and node take the corrected winner" True
  crLegacySpec
  crCorruptSpec

-- ---------------------------------------------------------------------
-- Bracket links (step 3): generateBracket writes the links in its own
-- transaction. Checked on first-insert and on offset stored ids.
-- ---------------------------------------------------------------------

-- Uses up 21 stored node ids with three throwaway brackets (one owner each, so
-- usernames stay unique): more than any domain id these sizes produce.
lgBurn :: SQLiteM ()
lgBurn = forM_ ["lg-burn-1", "lg-burn-2", "lg-burn-3"] $ \label -> do
  tid <- bsTournament label
  _ <- bsSave tid
  pure ()

-- (no type signature on purpose: it mentions TournamentFormat, whose import I have not seen)
lgGenerate burn fmt third label n = do
  BLM.when burn lgBurn
  ownerId <- createTestUser label
  let participants =
        [ Individual (Player (PlayerName ("P" ++ show i))) | i <- [1 .. n] ]
  tid <- createTournament NewTournament
    { newTournamentName = TournamentName "Links generation cup"
    , newTournamentOrganizer = OrganizerName "Test Organizer"
    , newTournamentOwner = ownerId, newTournamentFormat = fmt
    , newTournamentVisibility = Public, newTournamentMaxParticipants = n
    , newTournamentThirdPlaceMatch = third, newTournamentParticipantMode = IndividualOnly }
  forM_ participants $ \p -> case p of
    Individual player -> Repo.savePlayer player
    Squad team         -> Repo.saveTeam team
  advanceToRegistrationOpen ownerId tid
  forM_ participants (\p -> unwrap =<< registerParticipant tid p)
  _ <- unwrap =<< closeRegistration ownerId tid
  bracketId <- unwrap =<< generateBracket ownerId tid
  (_, nodes) <- Repo.getBracket bracketId
  let storedIds = [ BLIds.unBracketNodeId (BLBr.nodeId nd) | nd <- nodes ]
  -- the premise of every example here: stored ids start at 1 (control) or are offset past 21
  liftIO $ (if burn then minimum storedIds > 21 else minimum storedIds == 1) `shouldBe` True
  pure (ownerId, bracketId)

lgPointer :: BLBr.MatchSlot -> Maybe (Bool, BLIds.BracketNodeId)
lgPointer (BLBr.AwaitingWinnerOf s) = Just (True, s)
lgPointer (BLBr.AwaitingLoserOf s)  = Just (False, s)
lgPointer _                         = Nothing

lgPointerCount :: [BLBr.BracketNode] -> Int
lgPointerCount nodes =
  length [ () | n <- nodes, s <- [BLBr.nodeSlotA n, BLBr.nodeSlotB n], isJust (lgPointer s) ]

-- every pointer that survives bye resolution is backed by a link to the right node and slot
lgPointersAgree :: [BLBr.BracketNode] -> BLLin.BracketLinks -> Bool
lgPointersAgree nodes links = all agrees
  [ (BLBr.nodeId n, pos, ptr)
  | n <- nodes
  , (pos, slot) <- [(BLLin.SlotA, BLBr.nodeSlotA n), (BLLin.SlotB, BLBr.nodeSlotB n)]
  , Just ptr <- [lgPointer slot]
  ]
  where
    agrees (holder, pos, (isWinner, src)) =
      case lookup src links of
        Nothing -> False
        Just l  -> (if isWinner then BLLin.linkWinnerTo l else BLLin.linkLoserTo l)
                     == Just (BLLin.NodeDestination holder pos)

lgCommon :: [BLBr.BracketNode] -> BLLin.BracketLinks -> [(String, Bool)]
lgCommon nodes links =
  [ ("stored node ids are unique", length ids == length (BLList.nub ids))
  , ("exactly one link row per node, no duplicate sources", length keys == length (BLList.nub keys))
  , ("link rows cover exactly the stored nodes", BLList.sort keys == BLList.sort ids)
  , ("every surviving pointer is backed by a link to the right node and slot", lgPointersAgree nodes links)
  ]
  where
    ids  = map BLBr.nodeId nodes
    keys = map fst links

-- winner links of a single-elimination tree: one root in the top round, each destination one
-- round up, and every slot of every node above round 1 fed exactly once
lgWinnerShape :: [BLBr.BracketNode] -> BLLin.BracketLinks -> Bool
lgWinnerShape nodes links =
    length roots == 1
    && all ((== maxRound) . BLBr.nodeRound) roots
    && all stepsUp winnerDests
    && all (\n -> feeds n BLLin.SlotA == 1 && feeds n BLLin.SlotB == 1) upper
    && length winnerDests == 2 * length upper
  where
    winnerOf n = BLLin.linkWinnerTo =<< lookup (BLBr.nodeId n) links
    winnerDests = [ (n, d) | n <- nodes, Just d <- [winnerOf n] ]
    maxRound = maximum (map BLBr.nodeRound nodes)
    roots = [ n | n <- nodes, winnerOf n == Nothing ]
    upper = [ n | n <- nodes, BLBr.nodeRound n >= 2 ]
    roundOf i = BLBr.nodeRound <$> lookup i [ (BLBr.nodeId n, n) | n <- nodes ]
    stepsUp (n, d) = roundOf (BLLin.destNode d) == Just (BLBr.nodeRound n + 1)
    feeds n pos = length [ () | (_, d) <- winnerDests, BLLin.destNode d == BLBr.nodeId n, BLLin.destSlot d == pos ]

lgNoLosers :: BLLin.BracketLinks -> Bool
lgNoLosers links = all (\(_, l) -> BLLin.linkLoserTo l == Nothing) links

lgWithoutThird :: BLBr.Bracket -> [BLBr.BracketNode] -> [BLBr.BracketNode]
lgWithoutThird b nodes = [ n | n <- nodes, Just (BLBr.nodeId n) /= BLBr.bracketThirdPlaceNodeId b ]

-- the third-place node comes from the stored bracket header
lgThirdOk :: BLBr.Bracket -> [BLBr.BracketNode] -> BLLin.BracketLinks -> Bool
lgThirdOk bracket nodes links = case BLBr.bracketThirdPlaceNodeId bracket of
    Nothing -> False
    Just tp ->
      let maxRound = maximum (map BLBr.nodeRound nodes)
          semis = [ BLBr.nodeId n | n <- nodes, BLBr.nodeRound n == maxRound - 1 ]
          losers = [ (nid, d) | (nid, l) <- links, Just d <- [BLLin.linkLoserTo l] ]
          slots = map (BLLin.destSlot . snd) losers
      in BLList.sort (map fst losers) == BLList.sort semis
         && all ((== tp) . BLLin.destNode . snd) losers
         && length slots == 2 && BLLin.SlotA `elem` slots && BLLin.SlotB `elem` slots
         && lookup tp links == Just (BLLin.NodeLinks Nothing Nothing)

-- grand final and reset come from the stored bracket header
lgDeOk :: BLBr.Bracket -> [BLBr.BracketNode] -> BLLin.BracketLinks -> Bool
lgDeOk bracket nodes links =
  case (BLBr.bracketGF1NodeId bracket, BLBr.bracketResetNodeId bracket) of
    (Just gf1, Just reset) ->
      let gf1Round = maybe 0 BLBr.nodeRound (lookup gf1 [ (BLBr.nodeId n, n) | n <- nodes ])
          wbFinals = [ BLBr.nodeId n | n <- nodes, BLBr.nodeStage n == BLBr.Winners, BLBr.nodeRound n == gf1Round - 1 ]
          lbMax    = maximum (0 : [ BLBr.nodeRound n | n <- nodes, BLBr.nodeStage n == BLBr.Losers ])
          lbFinals = [ BLBr.nodeId n | n <- nodes, BLBr.nodeStage n == BLBr.Losers, BLBr.nodeRound n == lbMax ]
          winnerTo i = BLLin.linkWinnerTo =<< lookup i links
      in case (wbFinals, lbFinals) of
           ([wbF], [lbF]) ->
                winnerTo wbF == Just (BLLin.NodeDestination gf1 BLLin.SlotA)
             && winnerTo lbF == Just (BLLin.NodeDestination gf1 BLLin.SlotB)
             && lookup gf1 links == Just (BLLin.NodeLinks (Just (BLLin.NodeDestination reset BLLin.SlotA)) (Just (BLLin.NodeDestination reset BLLin.SlotB)))
             && lookup reset links == Just (BLLin.NodeLinks Nothing Nothing)
           _ -> False
    _ -> False

-- 4 players play 6 matches; a round robin has no pointers, so every row is all-null
lgRrOk :: [BLBr.BracketNode] -> BLLin.BracketLinks -> Bool
lgRrOk nodes links =
  length nodes == 6 && length links == 6 && all ((== BLLin.NodeLinks Nothing Nothing) . snd) links

lgPlainSe, lgThirdChecks, lgDeChecks, lgRrChecks :: BLBr.Bracket -> [BLBr.BracketNode] -> BLLin.BracketLinks -> [(String, Bool)]
lgPlainSe _ ns ls =
  [ ("winner links form a binary tree, every slot fed exactly once", lgWinnerShape ns ls)
  , ("no node has a loser destination", lgNoLosers ls) ]
lgThirdChecks b ns ls =
  [ ("main tree (third-place node excluded): winner links form a binary tree", lgWinnerShape (lgWithoutThird b ns) ls)
  , ("third-place routing agrees with the stored header", lgThirdOk b ns ls) ]
lgDeChecks b ns ls = [ ("double elimination routing agrees with the stored header", lgDeOk b ns ls) ]
lgRrChecks _ ns ls = [ ("round robin: 6 nodes, 6 all-null rows", lgRrOk ns ls) ]

lgCase title burn fmt third n extra =
  it title $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      (_, bid) <- lgGenerate burn fmt third "lg-owner" n
      (b, nodes) <- Repo.getBracket bid
      ls <- Repo.getBracketLinks bid
      pure (b, nodes, ls)
    case result of
      Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
      Right (_, _, Nothing) -> expectationFailure "generateBracket stored no links"
      Right (b, nodes, Just links) ->
        forM_ (lgCommon nodes links ++ extra b nodes links) $ \(name, ok) ->
          (name, ok) `shouldBe` (name, True)

lgStabilitySpec :: Spec
lgStabilitySpec = it "links are unchanged after a match is played, and the match really was completed" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      (ownerId, bid) <- lgGenerate True SingleElimination False "lg-stab-owner" 5
      (_, nodesBefore) <- Repo.getBracket bid
      before <- Repo.getBracketLinks bid
      ms <- Repo.listMatchesForBracket bid
      let round1 = [ BLBr.nodeId n | n <- nodesBefore, BLBr.nodeRound n == 1 ]
          m1 = head [ m | m <- ms, matchBracketNode m `elem` round1 ]
      _ <- unwrap =<< startMatch ownerId (matchId m1)
      _ <- unwrap =<< recordMatchResult ownerId (matchId m1) (Winner (matchCompetitorA m1))
      done <- Repo.getMatch (matchId m1)
      (_, nodesAfter) <- Repo.getBracket bid
      after <- Repo.getBracketLinks bid
      pure (before, after, done, matchCompetitorA m1, lgPointerCount nodesBefore, lgPointerCount nodesAfter)
    case result of
      Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
      Right (before, after, done, winner, pointersBefore, pointersAfter) -> do
        Match.matchStatus done `shouldBe` Match.Completed
        matchOutcome done `shouldBe` Just (Winner winner)
        pointersAfter `shouldSatisfy` (< pointersBefore)
        before `shouldSatisfy` isJust
        after `shouldBe` before

bracketLinksGenerationSpec :: Spec
bracketLinksGenerationSpec = describe "generateBracket writes bracket links" $ do
  lgCase "single elimination, 5 players, first-insert ids" False SingleElimination False 5 lgPlainSe
  lgCase "single elimination, 5 players, offset ids" True SingleElimination False 5 lgPlainSe
  lgCase "single elimination, 8 players, offset ids" True SingleElimination False 8 lgPlainSe
  lgCase "single elimination with third place, 8 players, first-insert ids" False SingleElimination True 8 lgThirdChecks
  lgCase "single elimination with third place, 8 players, offset ids" True SingleElimination True 8 lgThirdChecks
  lgCase "double elimination, 4 players, offset ids" True DoubleElimination False 4 lgDeChecks
  lgCase "double elimination, 6 players (byes), offset ids" True DoubleElimination False 6 lgDeChecks
  lgCase "round robin, 4 players, offset ids" True RoundRobin False 4 lgRrChecks
  lgStabilitySpec

-- ---------------------------------------------------------------------
-- Legacy and corrupt link data must fail closed: nothing written, nothing changed.
-- Three separate runs: set up and break the links, attempt the correction, read back
-- (a thrown StorageFailure aborts a run, so the read-back cannot share it).
-- ---------------------------------------------------------------------

crSnapshot bracketId downNodeId srcMatchId = do
  src <- Repo.getMatch srcMatchId
  ms <- Repo.listMatchesForBracket bracketId
  (_, nodes) <- Repo.getBracket bracketId
  pure ( src
       , [ m | m <- ms, matchBracketNode m == downNodeId ]
       , [ n | n <- nodes, BLBr.nodeId n == downNodeId ] )

crDropAllLinks :: BLIds.BracketId -> a -> SQLiteM ()
crDropAllLinks bracketId _ = do
  env <- ask
  liftIO $ execute (envConnection env) "DELETE FROM bracket_links WHERE bracket_id = ?" (Only (BLIds.unBracketId bracketId))

crDropOneLink :: a -> BLIds.BracketNodeId -> SQLiteM ()
crDropOneLink _ srcNode = do
  env <- ask
  liftIO $ execute (envConnection env) "DELETE FROM bracket_links WHERE node_id = ?" (Only (BLIds.unBracketNodeId srcNode))

crBrokenSpec title breakLinks expectAttempt =
  it title $ do
    prepared <- runSQLiteM testDbPath $ do
      setupSchema
      (ownerId, bracketId) <- crSetup True "cr-broken-owner" 5
      (_, nodesBefore) <- Repo.getBracket bracketId
      let round1NodeIds = map BLBr.nodeId (filter ((== 1) . BLBr.nodeRound) nodesBefore)
      matchesAtGen <- Repo.listMatchesForBracket bracketId
      let m1 = head (filter (\m -> matchBracketNode m `elem` round1NodeIds) matchesAtGen)
          downNodeId =
            case find (\nd -> BLBr.nodeSlotA nd == BLBr.AwaitingWinnerOf (matchBracketNode m1)
                           || BLBr.nodeSlotB nd == BLBr.AwaitingWinnerOf (matchBracketNode m1)) nodesBefore of
              Just nd -> BLBr.nodeId nd
              Nothing -> error "test setup invariant violated: m1 has no parent node"
      _ <- unwrap =<< startMatch ownerId (matchId m1)
      _ <- unwrap =<< recordMatchResult ownerId (matchId m1) (Winner (matchCompetitorA m1))
      breakLinks bracketId (matchBracketNode m1)
      snapshot <- crSnapshot bracketId downNodeId (matchId m1)
      pure (ownerId, bracketId, m1, downNodeId, snapshot)
    case prepared of
      Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
      Right (ownerId, bracketId, m1, downNodeId, before) -> do
        attempt <- runSQLiteM testDbPath (correctMatchResult ownerId (matchId m1) (Winner (matchCompetitorB m1)))
        expectAttempt attempt
        after <- runSQLiteM testDbPath (crSnapshot bracketId downNodeId (matchId m1))
        case after of
          Left err   -> expectationFailure ("read-back failed: " ++ show err)
          Right snap -> snap `shouldBe` before

crLegacySpec = crBrokenSpec
  "legacy bracket without links: correction is rejected with BracketLinksUnavailable and nothing changes"
  crDropAllLinks
  (\attempt -> case attempt of
      Right (Left BracketLinksUnavailable) -> pure ()
      other -> expectationFailure ("expected Right (Left BracketLinksUnavailable), got: " ++ show other))

crCorruptSpec = crBrokenSpec
  "corrupt links (one row missing): correction fails with StorageFailure and nothing changes"
  crDropOneLink
  bsExpectStorageFailure

-- ---------------------------------------------------------------------
-- Double elimination correction on offset stored node ids (reproduction only).
-- 4 players: two winners-bracket semifinals feed the winners final (winner) and
-- the first losers match (loser). Targets are found from the stored pointers
-- before anything is played, independent of any id arithmetic.
-- ---------------------------------------------------------------------

dcFacts nodesBefore matchesAtGen = (m1, target (BLBr.AwaitingWinnerOf src), target (BLBr.AwaitingLoserOf src))
  where
    m1 = head matchesAtGen
    src = matchBracketNode m1
    target p = case find (\nd -> BLBr.nodeSlotA nd == p || BLBr.nodeSlotB nd == p) nodesBefore of
      Just nd -> BLBr.nodeId nd
      Nothing -> error "test setup invariant violated: no node holds that pointer"

dcHolds :: [BLBr.BracketNode] -> BLIds.BracketNodeId -> Participant -> Bool
dcHolds nodes nid p = case filter ((== nid) . BLBr.nodeId) nodes of
  (nd : _) -> BLBr.nodeSlotA nd == BLBr.Filled p || BLBr.nodeSlotB nd == BLBr.Filled p
  []       -> False

-- Both semifinals played, the winners final started: correcting a semifinal must be rejected.
dcGuardSpec :: String -> Bool -> Spec
dcGuardSpec title burn =
  it title $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      (ownerId, bracketId) <- lgGenerate burn DoubleElimination False "dc-guard-owner" 4
      (_, nodesBefore) <- Repo.getBracket bracketId
      matchesAtGen <- Repo.listMatchesForBracket bracketId
      let (m1, winTarget, _) = dcFacts nodesBefore matchesAtGen
          m2 = head [ m | m <- matchesAtGen, matchId m /= matchId m1 ]
      _ <- unwrap =<< startMatch ownerId (matchId m1)
      _ <- unwrap =<< recordMatchResult ownerId (matchId m1) (Winner (matchCompetitorA m1))
      _ <- unwrap =<< startMatch ownerId (matchId m2)
      _ <- unwrap =<< recordMatchResult ownerId (matchId m2) (Winner (matchCompetitorA m2))
      allM <- Repo.listMatchesForBracket bracketId
      let wbFinalMatch = head [ m | m <- allM, matchBracketNode m == winTarget ]
      _ <- unwrap =<< startMatch ownerId (matchId wbFinalMatch)
      outcome <- correctMatchResult ownerId (matchId m1) (Winner (matchCompetitorB m1))
      pure (matchId wbFinalMatch, either Just (const Nothing) outcome)
    case result of
      Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
      Right (finalId, rejected) ->
        rejected `shouldBe` Just (DownstreamMatchStarted finalId)

-- One semifinal played, nothing downstream materialized: the correction must reach
-- both target nodes (winner into the winners final, loser into the first losers match).
dcRepairSpec :: String -> Bool -> Spec
dcRepairSpec title burn =
  it title $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      (ownerId, bracketId) <- lgGenerate burn DoubleElimination False "dc-repair-owner" 4
      (_, nodesBefore) <- Repo.getBracket bracketId
      matchesAtGen <- Repo.listMatchesForBracket bracketId
      let (m1, winTarget, loseTarget) = dcFacts nodesBefore matchesAtGen
          x = matchCompetitorA m1
          y = matchCompetitorB m1
      _ <- unwrap =<< startMatch ownerId (matchId m1)
      _ <- unwrap =<< recordMatchResult ownerId (matchId m1) (Winner x)
      (_, nodesPlayed) <- Repo.getBracket bracketId
      corrected <- unwrap =<< correctMatchResult ownerId (matchId m1) (Winner y)
      (_, nodesAfter) <- Repo.getBracket bracketId
      pure ( corrected, y
           , [ ("setup: winners final holds the recorded winner", dcHolds nodesPlayed winTarget x)
             , ("setup: first losers match holds the recorded loser", dcHolds nodesPlayed loseTarget y)
             , ("winners final holds the corrected winner", dcHolds nodesAfter winTarget y)
             , ("winners final no longer holds the old winner", not (dcHolds nodesAfter winTarget x))
             , ("first losers match holds the old winner as its new loser", dcHolds nodesAfter loseTarget x)
             , ("first losers match no longer holds the corrected winner", not (dcHolds nodesAfter loseTarget y)) ] )
    case result of
      Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
      Right (corrected, y, checks) -> do
        matchOutcome corrected `shouldBe` Just (Winner y)
        forM_ checks $ \(name, ok) -> (name, ok) `shouldBe` (name, True)

-- 6 players: the loser of the second winners round drops into a bye-shaped losers
-- node and is passed on. Correcting that match must follow the pass-through, and
-- must be refused once the node it was passed into has started.
dcPassThroughSpec :: String -> Bool -> Spec
dcPassThroughSpec title burn =
  it title $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      (ownerId, bracketId) <- lgGenerate burn DoubleElimination False "dc-pass-owner" 6
      (_, nodes0) <- Repo.getBracket bracketId
      mLinks <- Repo.getBracketLinks bracketId
      let links = case mLinks of
            Just l  -> l
            Nothing -> error "test setup: bracket has no stored links"
          isByeLb n = (BLBr.nodeStage n == BLBr.Losers) && (case (BLBr.nodeSlotA n, BLBr.nodeSlotB n) of
            (BLBr.AwaitingLoserOf _, BLBr.ByeSlot) -> True
            _                                      -> False)
          byeLb = head (filter isByeLb nodes0)
          srcOf s = case s of
            BLBr.AwaitingLoserOf i  -> i
            BLBr.AwaitingWinnerOf i -> i
            _                       -> error "test setup: unexpected slot"
          byeLbId = BLBr.nodeId byeLb
          n6Id = srcOf (BLBr.nodeSlotA byeLb)
          lb3Id = case blWinnerNode links byeLb of
            Just i  -> i
            Nothing -> error "test setup: bye node has no winner link"
          n9Id = srcOf (BLBr.nodeSlotA (blNodeById lb3Id nodes0))
          n5Id = srcOf (BLBr.nodeSlotA (blNodeById n9Id nodes0))
          lb1Id = srcOf (BLBr.nodeSlotB (blNodeById n9Id nodes0))
          n6 = blNodeById n6Id nodes0
          feeders = [srcOf (BLBr.nodeSlotA n6), srcOf (BLBr.nodeSlotB n6)]
          playNode nid = do
            ms <- Repo.listMatchesForBracket bracketId
            let m = head [ x | x <- ms, matchBracketNode x == nid ]
            _ <- unwrap =<< startMatch ownerId (matchId m)
            _ <- unwrap =<< recordMatchResult ownerId (matchId m) (Winner (matchCompetitorA m))
            pure m
      mapM_ playNode feeders
      m6 <- playNode n6Id
      let x = matchCompetitorA m6
          y = matchCompetitorB m6
      (_, nodesPlayed) <- Repo.getBracket bracketId
      corrected <- unwrap =<< correctMatchResult ownerId (matchId m6) (Winner y)
      (_, nodesAfter) <- Repo.getBracket bracketId
      _ <- playNode n5Id
      _ <- playNode lb1Id
      _ <- playNode n9Id
      ms <- Repo.listMatchesForBracket bracketId
      let lb3Match = head [ m | m <- ms, matchBracketNode m == lb3Id ]
      _ <- unwrap =<< startMatch ownerId (matchId lb3Match)
      late <- correctMatchResult ownerId (matchId m6) (Winner x)
      m6After <- Repo.getMatch (matchId m6)
      pure ( corrected, y
           , [ ("setup: bye-shaped node holds the recorded loser", dcHolds nodesPlayed byeLbId y)
             , ("setup: the node it was passed into holds the recorded loser", dcHolds nodesPlayed lb3Id y)
             , ("bye-shaped node holds the old winner as its new loser", dcHolds nodesAfter byeLbId x)
             , ("pass-through node follows the correction", dcHolds nodesAfter lb3Id x)
             , ("pass-through node no longer holds the corrected winner", not (dcHolds nodesAfter lb3Id y)) ]
           , (matchId lb3Match, either Just (const Nothing) late, matchOutcome m6After) )
    case result of
      Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
      Right (corrected, y, checks, (lb3MatchId, rejected, m6Outcome)) -> do
        matchOutcome corrected `shouldBe` Just (Winner y)
        forM_ checks $ \(name, ok) -> (name, ok) `shouldBe` (name, True)
        rejected `shouldBe` Just (DownstreamMatchStarted lb3MatchId)
        m6Outcome `shouldBe` Just (Winner y)

doubleElimNodeIdSpec :: Spec
doubleElimNodeIdSpec = describe "NodeIdSpace: CorrectMatchResult (Double Elim)" $ do
  dcGuardSpec  "guard, control (first-insert ids): rejects with DownstreamMatchStarted once the winners final has started" False
  dcGuardSpec  "guard, offset ids: rejects with DownstreamMatchStarted once the winners final has started" True
  dcRepairSpec "repair, control (first-insert ids): both target nodes take the corrected result" False
  dcRepairSpec "repair, offset ids: both target nodes take the corrected result" True
  dcFinalRepairSpec "final repair, control (first-insert ids): the grand final and the losers final take the corrected result" False
  dcFinalRepairSpec "final repair, offset ids: the grand final and the losers final take the corrected result" True
  dcPassThroughSpec "pass-through, control (first-insert ids): correction follows a loser passed through a bye node and is refused once that node started" False
  dcPassThroughSpec "pass-through, offset ids: correction follows a loser passed through a bye node and is refused once that node started" True
  dcLbRepairSpec "losers match repair, control (first-insert ids): the losers final takes the corrected winner" False
  dcLbRepairSpec "losers match repair, offset ids: the losers final takes the corrected winner" True
  dcLegacySpec
  dcCorruptSpec

-- ---------------------------------------------------------------------
-- DE lineage parity (tests only, no source change): on first-insert brackets the
-- stored links must reproduce exactly what the template-based lineage helpers
-- resolve today, including where they decline, so that switching double
-- elimination correction to the links preserves its behavior.
-- Old plan = (winner target, loser target) as correctDoubleElimination computes it;
-- new plan = what the links say. A final's winner goes to the grand final.
-- ---------------------------------------------------------------------

dpPlans players =
  [ (BLBr.nodeId n, oldPlan n, newPlan n) | n <- wb ++ lb ]
  where
    size = BLGen.bracketSize players
    (wb, allNodes, gf1, _) = blDe players
    lb = [ n | n <- allNodes, BLBr.nodeStage n == BLBr.Losers ]
    links = blDerive allNodes
    orGf1 = maybe (Just gf1) Just
    oldPlan n
      | BLBr.nodeStage n == BLBr.Winners =
          ( orGf1 (BLLD.resolveWBWinnerTarget size (BLBr.nodeId n))
          , either (const Nothing) Just (BLLD.resolveWBLoserTarget wb size (BLBr.nodeId n)) )
      | otherwise = ( orGf1 (BLLD.resolveLBTarget wb size (BLBr.nodeId n)), Nothing )
    newPlan n = (blWinnerNode links n, blLoserNode links n)

dpSpec :: Int -> Spec
dpSpec players =
  it ("double elimination, " ++ show players ++ " players: links reproduce the lineage helpers' targets, including where they decline") $ do
    let plans = dpPlans players
    [ p | p@(_, o, nw) <- plans, o /= nw ] `shouldBe` []
    -- not vacuous: some node really has a loser target to compare
    length [ () | (_, (_, l), _) <- plans, l /= Nothing ] `shouldSatisfy` (> 0)

doubleElimParitySpec :: Spec
doubleElimParitySpec = describe "DEParity: stored links reproduce the lineage helpers" $
  mapM_ dpSpec [4 .. 16]

-- ---------------------------------------------------------------------
-- Double elimination correction on the stored links: winners final, losers
-- match, and legacy / corrupt link data. Each repair scenario runs as a control
-- (first-insert ids) and with offset ids.
-- ---------------------------------------------------------------------

dcHolder nodes p = case find (\nd -> BLBr.nodeSlotA nd == p || BLBr.nodeSlotB nd == p) nodes of
  Just nd -> BLBr.nodeId nd
  Nothing -> error "test setup invariant violated: no node holds that pointer"

dcPlaySemis ownerId m1 m2 = do
  _ <- unwrap =<< startMatch ownerId (matchId m1)
  _ <- unwrap =<< recordMatchResult ownerId (matchId m1) (Winner (matchCompetitorA m1))
  _ <- unwrap =<< startMatch ownerId (matchId m2)
  _ <- unwrap =<< recordMatchResult ownerId (matchId m2) (Winner (matchCompetitorA m2))
  pure ()

-- winners final played, then corrected: grand final (slot A, the winner) and losers final
-- (slot A, the loser) must both follow
dcFinalRepairSpec :: String -> Bool -> Spec
dcFinalRepairSpec title burn =
  it title $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      (ownerId, bracketId) <- lgGenerate burn DoubleElimination False "dc-final-owner" 4
      (_, nodesBefore) <- Repo.getBracket bracketId
      matchesAtGen <- Repo.listMatchesForBracket bracketId
      let (m1, fNode, _) = dcFacts nodesBefore matchesAtGen
          m2 = head [ m | m <- matchesAtGen, matchId m /= matchId m1 ]
          gfNode = dcHolder nodesBefore (BLBr.AwaitingWinnerOf fNode)
          lfNode = dcHolder nodesBefore (BLBr.AwaitingLoserOf fNode)
      dcPlaySemis ownerId m1 m2
      allM <- Repo.listMatchesForBracket bracketId
      let fMatch = head [ m | m <- allM, matchBracketNode m == fNode ]
          x = matchCompetitorA fMatch
          y = matchCompetitorB fMatch
      _ <- unwrap =<< startMatch ownerId (matchId fMatch)
      _ <- unwrap =<< recordMatchResult ownerId (matchId fMatch) (Winner x)
      (_, nodesPlayed) <- Repo.getBracket bracketId
      corrected <- unwrap =<< correctMatchResult ownerId (matchId fMatch) (Winner y)
      (_, nodesAfter) <- Repo.getBracket bracketId
      pure ( corrected, y
           , [ ("setup: grand final holds the recorded winner", dcHolds nodesPlayed gfNode x)
             , ("setup: losers final holds the recorded loser", dcHolds nodesPlayed lfNode y)
             , ("grand final holds the corrected winner", dcHolds nodesAfter gfNode y)
             , ("grand final no longer holds the old winner", not (dcHolds nodesAfter gfNode x))
             , ("losers final holds the old winner as its new loser", dcHolds nodesAfter lfNode x)
             , ("losers final no longer holds the corrected winner", not (dcHolds nodesAfter lfNode y)) ] )
    case result of
      Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
      Right (corrected, y, checks) -> do
        matchOutcome corrected `shouldBe` Just (Winner y)
        forM_ checks $ \(name, ok) -> (name, ok) `shouldBe` (name, True)

-- first losers match played, then corrected: the losers final (slot B) must follow
dcLbRepairSpec :: String -> Bool -> Spec
dcLbRepairSpec title burn =
  it title $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      (ownerId, bracketId) <- lgGenerate burn DoubleElimination False "dc-lb-owner" 4
      (_, nodesBefore) <- Repo.getBracket bracketId
      matchesAtGen <- Repo.listMatchesForBracket bracketId
      let (m1, _, l1Node) = dcFacts nodesBefore matchesAtGen
          m2 = head [ m | m <- matchesAtGen, matchId m /= matchId m1 ]
          lfNode = dcHolder nodesBefore (BLBr.AwaitingWinnerOf l1Node)
      dcPlaySemis ownerId m1 m2
      allM <- Repo.listMatchesForBracket bracketId
      let l1Match = head [ m | m <- allM, matchBracketNode m == l1Node ]
          x = matchCompetitorA l1Match
          y = matchCompetitorB l1Match
      _ <- unwrap =<< startMatch ownerId (matchId l1Match)
      _ <- unwrap =<< recordMatchResult ownerId (matchId l1Match) (Winner x)
      (_, nodesPlayed) <- Repo.getBracket bracketId
      corrected <- unwrap =<< correctMatchResult ownerId (matchId l1Match) (Winner y)
      (_, nodesAfter) <- Repo.getBracket bracketId
      pure ( corrected, y
           , [ ("setup: losers final holds the recorded winner", dcHolds nodesPlayed lfNode x)
             , ("losers final holds the corrected winner", dcHolds nodesAfter lfNode y)
             , ("losers final no longer holds the old winner", not (dcHolds nodesAfter lfNode x)) ] )
    case result of
      Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
      Right (corrected, y, checks) -> do
        matchOutcome corrected `shouldBe` Just (Winner y)
        forM_ checks $ \(name, ok) -> (name, ok) `shouldBe` (name, True)

dcSnapshot bracketId winTarget loseTarget srcMatchId = do
  src <- Repo.getMatch srcMatchId
  ms <- Repo.listMatchesForBracket bracketId
  (_, nodes) <- Repo.getBracket bracketId
  pure ( src
       , [ m | m <- ms, matchBracketNode m `elem` [winTarget, loseTarget] ]
       , [ n | n <- nodes, BLBr.nodeId n `elem` [winTarget, loseTarget] ] )

dcBrokenSpec title breakLinks expectAttempt =
  it title $ do
    prepared <- runSQLiteM testDbPath $ do
      setupSchema
      (ownerId, bracketId) <- lgGenerate True DoubleElimination False "dc-broken-owner" 4
      (_, nodesBefore) <- Repo.getBracket bracketId
      matchesAtGen <- Repo.listMatchesForBracket bracketId
      let (m1, winTarget, loseTarget) = dcFacts nodesBefore matchesAtGen
      _ <- unwrap =<< startMatch ownerId (matchId m1)
      _ <- unwrap =<< recordMatchResult ownerId (matchId m1) (Winner (matchCompetitorA m1))
      breakLinks bracketId (matchBracketNode m1)
      snapshot <- dcSnapshot bracketId winTarget loseTarget (matchId m1)
      pure (ownerId, bracketId, m1, winTarget, loseTarget, snapshot)
    case prepared of
      Left err -> expectationFailure ("runSQLiteM failed: " ++ show err)
      Right (ownerId, bracketId, m1, winTarget, loseTarget, before) -> do
        attempt <- runSQLiteM testDbPath (correctMatchResult ownerId (matchId m1) (Winner (matchCompetitorB m1)))
        expectAttempt attempt
        after <- runSQLiteM testDbPath (dcSnapshot bracketId winTarget loseTarget (matchId m1))
        case after of
          Left err   -> expectationFailure ("read-back failed: " ++ show err)
          Right snap -> snap `shouldBe` before

dcLegacySpec = dcBrokenSpec
  "double elimination, legacy bracket without links: correction is rejected with BracketLinksUnavailable and nothing changes"
  crDropAllLinks
  (\attempt -> case attempt of
      Right (Left BracketLinksUnavailable) -> pure ()
      other -> expectationFailure ("expected Right (Left BracketLinksUnavailable), got: " ++ show other))

dcCorruptSpec = dcBrokenSpec
  "double elimination, corrupt links (one row missing): correction fails with StorageFailure and nothing changes"
  crDropOneLink
  bsExpectStorageFailure

-- ---------------------------------------------------------------------
-- Step 4: the bracket read model carries the stored links.
-- ---------------------------------------------------------------------

gvView ownerId bracketId = do
  (b, _) <- Repo.getBracket bracketId
  unwrap =<< GBV.getBracket (Just ownerId) (BLBr.bracketTournament b)

bracketLinksViewSpec :: Spec
bracketLinksViewSpec = describe "GetBracket read model carries the stored bracket links" $ do
  it "a generated bracket with offset ids exposes exactly the stored links" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      (ownerId, bracketId) <- lgGenerate True SingleElimination False "gv-owner-1" 5
      v <- gvView ownerId bracketId
      stored <- Repo.getBracketLinks bracketId
      pure (GBV.viewLinks v, stored, map BLBr.nodeId (GBV.viewNodes v))
    case result of
      Left err -> expectationFailure (show err)
      Right (viewLinks, stored, viewNodeIds) -> do
        viewLinks `shouldSatisfy` isJust
        viewLinks `shouldBe` stored
        fmap (map fst) viewLinks `shouldBe` Just (BLList.sort viewNodeIds)

  it "a bracket without stored links reads as no links" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      (ownerId, bracketId) <- lgGenerate True SingleElimination False "gv-owner-2" 5
      crDropAllLinks bracketId ()
      v <- gvView ownerId bracketId
      pure (GBV.viewLinks v)
    case result of
      Left err -> expectationFailure (show err)
      Right links -> links `shouldBe` Nothing

  it "corrupt links make the read fail loudly instead of silently dropping the links" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      (ownerId, bracketId) <- lgGenerate True SingleElimination False "gv-owner-3" 5
      (_, nodes) <- Repo.getBracket bracketId
      crDropOneLink bracketId (BLBr.nodeId (head nodes))
      gvView ownerId bracketId
    bsExpectStorageFailure result

-- Round robin ordering helpers: each node as (index of A, index of B), 1-based.
rrNodePairs ps nodes =
  [ (slotIdx (nodeSlotA n), slotIdx (nodeSlotB n)) | n <- nodes ]
  where
    slotIdx (Filled p) = head ([ i | (i, q) <- zip [1 :: Int ..] ps, q == p ] ++ [0])
    slotIdx _ = 0

-- Longest run of consecutive matches any one player appears in.
rrLongestStreak n pairs =
  maximum [ run [ k == a || k == b | (a, b) <- pairs ] | k <- [1 .. n] ]
  where
    run = go 0 0
    go best cur [] = max best cur
    go best cur (x : xs)
      | x = go (max best (cur + 1)) (cur + 1) xs
      | otherwise = go best 0 xs

-- ---------------------------------------------------------------------
-- v0.12: optional game / start time / prize, and registered counts.
-- ---------------------------------------------------------------------

dtNew :: UserId -> String -> NewTournament
dtNew owner name = NewTournament
  { newTournamentName            = TournamentName name
  , newTournamentOrganizer       = OrganizerName "Test Organizer"
  , newTournamentOwner           = owner
  , newTournamentFormat          = SingleElimination
  , newTournamentVisibility      = Public
  , newTournamentMaxParticipants = 4
  , newTournamentThirdPlaceMatch = False
  , newTournamentParticipantMode = IndividualOnly
  }

dtTime :: UTCTime
dtTime = UTCTime (fromGregorian 2026 12 12) 64800

dtDetails :: TournamentDetails
dtDetails = TournamentDetails (Just GameEFootball) (Just dtTime) (Just 50000) Nothing Nothing

dtCreate :: UserId -> String -> TournamentDetails -> SQLiteM TournamentId
dtCreate owner name d = unwrap =<< CTD.createTournamentWithDetails (dtNew owner name) d

dtTriple :: Tournament -> (Maybe Game, Maybe UTCTime, Maybe Int)
dtTriple t = (tournamentGame t, tournamentStartTime t, tournamentPrize t)

dtChanged :: TournamentId -> SQLiteM [TournamentHistory.ChangedField]
dtChanged tid = do
  entries <- Repo.getTournamentHistory tid
  pure [ f | TournamentHistoryEntry { historyEvent = ConfigurationChanged f } <- entries ]

detailsSpec :: Spec
detailsSpec = describe "Tournament details: game, start time, prize in KSh (v0.12)" $ do

  it "creates with details and reads them back" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      owner <- createTestUser "dt-owner-1"
      tid <- dtCreate owner "Details Cup" dtDetails
      Repo.getTournament tid
    case result of
      Left err -> expectationFailure (show err)
      Right t  -> dtTriple t `shouldBe` (Just GameEFootball, Just dtTime, Just 50000)

  it "creates without details: all three fields are absent" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      owner <- createTestUser "dt-owner-2"
      tid <- dtCreate owner "Plain Cup" noDetails
      Repo.getTournament tid
    case result of
      Left err -> expectationFailure (show err)
      Right t  -> dtTriple t `shouldBe` (Nothing, Nothing, Nothing)

  it "stores the start time in whole seconds" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      owner <- createTestUser "dt-owner-3"
      tid <- dtCreate owner "Seconds Cup" (noDetails { detailsStartTime = Just (UTCTime (fromGregorian 2026 12 12) 64800.75) })
      Repo.getTournament tid
    case result of
      Left err -> expectationFailure (show err)
      Right t  -> tournamentStartTime t `shouldBe` Just dtTime

  it "treats a zero prize as no prize" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      owner <- createTestUser "dt-owner-4"
      tid <- dtCreate owner "Zero Prize Cup" (noDetails { detailsPrize = Just 0 })
      Repo.getTournament tid
    case result of
      Left err -> expectationFailure (show err)
      Right t  -> tournamentPrize t `shouldBe` Nothing

  it "accepts the largest prize and rejects anything outside the range, creating nothing" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      owner <- createTestUser "dt-owner-5"
      ok   <- CTD.createTournamentWithDetails (dtNew owner "Ok") (noDetails { detailsPrize = Just 1000000000 })
      high <- CTD.createTournamentWithDetails (dtNew owner "High") (noDetails { detailsPrize = Just 1000000001 })
      neg  <- CTD.createTournamentWithDetails (dtNew owner "Negative") (noDetails { detailsPrize = Just (-5) })
      everything <- Repo.listAllTournaments
      pure (isRight ok, high, neg, map tournamentName everything)
    case result of
      Left err -> expectationFailure (show err)
      Right (okRight, high, neg, names) -> do
        okRight `shouldBe` True
        high `shouldBe` Left (CTD.CreateInvalidDetails (DV.PrizeOutOfRange 1000000001))
        neg `shouldBe` Left (CTD.CreateInvalidDetails (DV.PrizeOutOfRange (-5)))
        names `shouldBe` [TournamentName "Ok"]

  it "update replaces the details and logs one history entry per changed field" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      owner <- createTestUser "dt-owner-6"
      tid <- dtCreate owner "Edit Cup" (TournamentDetails (Just GameEFootball) Nothing (Just 10000) Nothing Nothing)
      r <- UTD.updateTournamentDetails owner tid (TournamentDetails (Just GameEFootball) (Just dtTime) (Just 20000) Nothing Nothing)
      t <- Repo.getTournament tid
      changed <- dtChanged tid
      pure (r, t, changed)
    case result of
      Left err -> expectationFailure (show err)
      Right (r, t, changed) -> do
        r `shouldBe` Right ()
        dtTriple t `shouldBe` (Just GameEFootball, Just dtTime, Just 20000)
        changed `shouldMatchList` [TournamentHistory.FieldStartTime, TournamentHistory.FieldPrize]

  it "an update that changes nothing logs nothing" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      owner <- createTestUser "dt-owner-7"
      tid <- dtCreate owner "Same Cup" dtDetails
      r <- UTD.updateTournamentDetails owner tid dtDetails
      changed <- dtChanged tid
      pure (r, changed)
    case result of
      Left err -> expectationFailure (show err)
      Right (r, changed) -> do
        r `shouldBe` Right ()
        changed `shouldBe` []

  it "an update with no fields clears all three" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      owner <- createTestUser "dt-owner-8"
      tid <- dtCreate owner "Clear Cup" dtDetails
      r <- UTD.updateTournamentDetails owner tid noDetails
      t <- Repo.getTournament tid
      changed <- dtChanged tid
      pure (r, t, changed)
    case result of
      Left err -> expectationFailure (show err)
      Right (r, t, changed) -> do
        r `shouldBe` Right ()
        dtTriple t `shouldBe` (Nothing, Nothing, Nothing)
        changed `shouldMatchList`
          [TournamentHistory.FieldGame, TournamentHistory.FieldStartTime, TournamentHistory.FieldPrize]

  it "rejects a non-owner and leaves the tournament unchanged" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      owner <- createTestUser "dt-owner-9"
      other <- createTestUser "dt-other-9"
      tid <- dtCreate owner "Guarded Cup" dtDetails
      before <- Repo.getTournament tid
      r <- UTD.updateTournamentDetails other tid noDetails
      after <- Repo.getTournament tid
      pure (r, before, after)
    case result of
      Left err -> expectationFailure (show err)
      Right (r, before, after) -> do
        r `shouldBe` Left (UTD.Unauthorized NotTournamentOwner)
        after `shouldBe` before

  it "is locked once the tournament is cancelled" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      owner <- createTestUser "dt-owner-10"
      tid <- dtCreate owner "Locked Cup" dtDetails
      _ <- unwrap =<< cancelTournament owner tid "no longer needed"
      before <- Repo.getTournament tid
      r <- UTD.updateTournamentDetails owner tid noDetails
      after <- Repo.getTournament tid
      pure (r, before, after)
    case result of
      Left err -> expectationFailure (show err)
      Right (r, before, after) -> do
        case r of
          Left (UTD.InvalidLifecycle _) -> pure ()
          other -> expectationFailure ("expected InvalidLifecycle, got: " ++ show other)
        after `shouldBe` before

  it "a prize out of range on update is rejected and nothing changes" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      owner <- createTestUser "dt-owner-11"
      tid <- dtCreate owner "Range Cup" dtDetails
      before <- Repo.getTournament tid
      r <- UTD.updateTournamentDetails owner tid (dtDetails { detailsPrize = Just 1000000001 })
      after <- Repo.getTournament tid
      pure (r, before, after)
    case result of
      Left err -> expectationFailure (show err)
      Right (r, before, after) -> do
        r `shouldBe` Left (UTD.InvalidDetails (DV.PrizeOutOfRange 1000000001))
        after `shouldBe` before

  it "saveTournament and publishing keep the details" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      owner <- createTestUser "dt-owner-12"
      tid <- dtCreate owner "Keep Cup" dtDetails
      t0 <- Repo.getTournament tid
      Repo.saveTournament t0
      t1 <- Repo.getTournament tid
      _ <- unwrap =<< publishTournament owner tid
      t2 <- Repo.getTournament tid
      pure (t0, t1, t2)
    case result of
      Left err -> expectationFailure (show err)
      Right (t0, t1, t2) -> do
        t1 `shouldBe` t0
        dtTriple t2 `shouldBe` dtTriple t0

  it "countRegistrationsByTournament matches real registrations" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      owner <- createTestUser "dt-owner-13"
      busy  <- createOpenTournament owner "Busy Cup" 4
      empty <- createOpenTournament owner "Empty Cup" 4
      let alice = Individual (Player (PlayerName "CountAlice"))
          bob   = Individual (Player (PlayerName "CountBob"))
      Repo.savePlayer (Player (PlayerName "CountAlice"))
      Repo.savePlayer (Player (PlayerName "CountBob"))
      forM_ [alice, bob] (\p -> unwrap =<< registerParticipant busy p)
      counts <- Repo.countRegistrationsByTournament
      pure (busy, empty, counts)
    case result of
      Left err -> expectationFailure (show err)
      Right (busy, empty, counts) -> do
        lookup busy counts `shouldBe` Just 2
        lookup empty counts `shouldBe` Nothing

  it "migrates a pre-v0.11 database in place and is safe to run twice" $ do
    let path = "test/arenaos-migrate-test.db"
    exists <- doesFileExist path
    if exists then removeFile path else pure ()
    conn <- SQLite.open path
    SQLite.execute_ conn "CREATE TABLE tournaments ( id INTEGER PRIMARY KEY, name TEXT NOT NULL, organizer_name TEXT NOT NULL, owner_id INTEGER NOT NULL, format TEXT NOT NULL, state TEXT NOT NULL, visibility TEXT NOT NULL, third_place_match INTEGER NOT NULL DEFAULT 0, participant_mode TEXT NOT NULL DEFAULT 'IndividualOnly', max_participants INTEGER NOT NULL, bracket_id INTEGER )"
    SQLite.execute_ conn "INSERT INTO tournaments (id, name, organizer_name, owner_id, format, state, visibility, max_participants) VALUES (1, 'Old Cup', 'Org', 1, 'SingleElimination', 'Draft', 'Public', 4)"
    initializeSchema conn
    initializeSchema conn
    SQLite.close conn
    result <- runSQLiteM path (Repo.getTournament (TournamentId 1))
    removeFile path
    case result of
      Left err -> expectationFailure (show err)
      Right t -> do
        tournamentName t `shouldBe` TournamentName "Old Cup"
        dtTriple t `shouldBe` (Nothing, Nothing, Nothing)

  it "migrates a database that still has the old free-text prize and ignores that text" $ do
    let path = "test/arenaos-migrate-test.db"
    exists <- doesFileExist path
    if exists then removeFile path else pure ()
    conn <- SQLite.open path
    SQLite.execute_ conn "CREATE TABLE tournaments ( id INTEGER PRIMARY KEY, name TEXT NOT NULL, organizer_name TEXT NOT NULL, owner_id INTEGER NOT NULL, format TEXT NOT NULL, state TEXT NOT NULL, visibility TEXT NOT NULL, third_place_match INTEGER NOT NULL DEFAULT 0, participant_mode TEXT NOT NULL DEFAULT 'IndividualOnly', max_participants INTEGER NOT NULL, bracket_id INTEGER, game TEXT, start_time TEXT, prize TEXT )"
    SQLite.execute_ conn "INSERT INTO tournaments (id, name, organizer_name, owner_id, format, state, visibility, max_participants, game, prize) VALUES (1, 'Text Prize Cup', 'Org', 1, 'SingleElimination', 'Draft', 'Public', 4, 'eFootball', 'KSh 10,000 and a trophy')"
    initializeSchema conn
    SQLite.close conn
    result <- runSQLiteM path (Repo.getTournament (TournamentId 1))
    removeFile path
    case result of
      Left err -> expectationFailure (show err)
      Right t -> dtTriple t `shouldBe` (Just GameEFootball, Nothing, Nothing)


-- ----------------------------------------------------------------------- v0.12: public stats for the home page.
-- ---------------------------------------------------------------------

stPublish :: UserId -> String -> Maybe Game -> SQLiteM TournamentId
stPublish owner name g = do
  tid <- dtCreate owner name (noDetails { detailsGame = g })
  _ <- unwrap =<< publishTournament owner tid
  pure tid

statsSpec :: Spec
statsSpec = describe "Public stats (v0.12)" $ do

  it "is all zeros on an empty database" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      Repo.publicStats
    case result of
      Left err -> expectationFailure (show err)
      Right s  -> s `shouldBe` PublicStats 0 0 0 0 0 []

  it "counts only Public tournaments past Draft; active means open or running" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      owner <- createTestUser "st-owner-1"
      _ <- dtCreate owner "Still Draft" noDetails
      _ <- createOpenTournament owner "Open Public" 4
      priv <- createTournament ((dtNew owner "Open Private") { newTournamentVisibility = Private })
      advanceToRegistrationOpen owner priv
      cancelled <- dtCreate owner "Cancelled Public" noDetails
      _ <- unwrap =<< cancelTournament owner cancelled "no longer needed"
      Repo.publicStats
    case result of
      Left err -> expectationFailure (show err)
      Right s  -> do
        statsTournaments s `shouldBe` 2
        statsActiveTournaments s `shouldBe` 1

  it "counts distinct players and teams across public tournaments only" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      owner <- createTestUser "st-owner-2"
      let alice = Player (PlayerName "StatsAlice")
          bob   = Player (PlayerName "StatsBob")
          zed   = Player (PlayerName "StatsZed")
          falcons = Team
            { teamName    = TeamName "StatsFalcons"
            , teamCaptain = Player (PlayerName "StatsCap")
            , teamMembers = [Player (PlayerName "StatsCap"), Player (PlayerName "StatsMate")]
            }
      mapM_ Repo.savePlayer [alice, bob, zed]
      one <- createOpenTournament owner "Solo One" 4
      two <- createOpenTournament owner "Solo Two" 4
      forM_ [alice, bob] (\p -> unwrap =<< registerParticipant one (Individual p))
      _ <- unwrap =<< registerParticipant two (Individual alice)
      squadT <- createOpenTournamentWithMode owner "Squad One" 4 SquadOnly
      _ <- unwrap =<< createTeam falcons
      _ <- unwrap =<< registerParticipant squadT (Squad falcons)
      priv <- createTournament ((dtNew owner "Hidden") { newTournamentVisibility = Private })
      advanceToRegistrationOpen owner priv
      _ <- unwrap =<< registerParticipant priv (Individual zed)
      Repo.publicStats
    case result of
      Left err -> expectationFailure (show err)
      Right s  -> do
        statsPlayers s `shouldBe` 4
        statsTeams s `shouldBe` 1

  it "counts public non-draft tournaments per game" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      owner <- createTestUser "st-owner-3"
      _ <- stPublish owner "E1" (Just GameEFootball)
      _ <- stPublish owner "E2" (Just GameEFootball)
      _ <- stPublish owner "C1" (Just GameCallOfDuty)
      _ <- stPublish owner "No Game" Nothing
      _ <- dtCreate owner "E Draft" (noDetails { detailsGame = Just GameEFootball })
      priv <- unwrap =<< CTD.createTournamentWithDetails
                ((dtNew owner "E Private") { newTournamentVisibility = Private })
                (noDetails { detailsGame = Just GameEFootball })
      _ <- unwrap =<< publishTournament owner priv
      Repo.publicStats
    case result of
      Left err -> expectationFailure (show err)
      Right s  -> statsByGame s `shouldMatchList` [(GameEFootball, 2), (GameCallOfDuty, 1)]

-- ---------------------------------------------------------------------
-- v0.12: server-side filtering of the public list (pure selection).
-- ---------------------------------------------------------------------

plT :: Int -> String -> Maybe Game -> Tournament
plT i name g = Tournament
  { tournamentId = TournamentId i, tournamentName = TournamentName name
  , tournamentOrganizer = OrganizerName "x", tournamentFormat = SingleElimination
  , tournamentState = Published, tournamentVisibility = Public
  , tournamentMaxParticipants = 2, tournamentBracket = Nothing
  , tournamentOwner = UserId 1, tournamentThirdPlaceMatch = False
  , tournamentParticipantMode = IndividualOnly
  , tournamentGame = g, tournamentStartTime = Nothing, tournamentPrize = Nothing, tournamentDescription = Nothing, tournamentRequireApproval = False, tournamentRegistrationDeadline = Nothing }

-- ids 1..60; id 3 is "Zebra Open" (Call of Duty); other even ids are eFootball
plAll :: [Tournament]
plAll = [ plT i (if i == 3 then "Zebra Open" else "Cup " ++ show i) (plGame i) | i <- [1 .. 60] ]
  where
    plGame i
      | i == 3         = Just GameCallOfDuty
      | i `mod` 2 == 0 = Just GameEFootball
      | otherwise      = Nothing

plHidden :: [Tournament]
plHidden =
  [ (plT 100 "Cup hidden" (Just GameEFootball)) { tournamentState = Draft }
  , (plT 101 "Cup hidden" (Just GameEFootball)) { tournamentVisibility = Private }
  ]

plIds :: [Tournament] -> [Int]
plIds = map (unTournamentId . tournamentId)

publicFilterSpec :: Spec
publicFilterSpec = describe "Public list filtering (v0.12)" $ do

  it "defaults behave exactly like the old selection" $
    LP.selectPublicFiltered LP.defaultPublicFilter plAll `shouldBe` LP.selectPublic 50 plAll

  it "matches names case-insensitively and finds tournaments older than the newest 50" $
    plIds (LP.selectPublicFiltered (LP.defaultPublicFilter { LP.pfQuery = Just "  zEbRa " }) plAll)
      `shouldBe` [3]

  it "filters by game before applying the cap" $
    plIds (LP.selectPublicFiltered (LP.defaultPublicFilter { LP.pfGame = Just GameCallOfDuty }) plAll)
      `shouldBe` [3]

  it "combines the name and game filters" $
    plIds (LP.selectPublicFiltered
             (LP.defaultPublicFilter { LP.pfQuery = Just "cup", LP.pfGame = Just GameEFootball }) plAll)
      `shouldBe` [60, 58 .. 2]

  it "returns newest first and respects the limit" $
    plIds (LP.selectPublicFiltered (LP.defaultPublicFilter { LP.pfLimit = 3 }) plAll)
      `shouldBe` [60, 59, 58]

  it "never shows Draft or Private tournaments, whatever the filters" $
    plIds (LP.selectPublicFiltered (LP.defaultPublicFilter { LP.pfQuery = Just "hidden" }) plHidden)
      `shouldBe` []

-- ---------------------------------------------------------------------
-- v0.12: "upcoming" filter on the public list (pure selection).
-- ---------------------------------------------------------------------

ucfNow :: UTCTime
ucfNow = UTCTime (fromGregorian 2026 10 20) 0

ucfDay :: Int -> Int -> UTCTime
ucfDay m d = UTCTime (fromGregorian 2026 m d) 0

ucfT :: Int -> Maybe Game -> Maybe UTCTime -> TournamentState -> Tournament
ucfT i g st s = (plT i ("Up " ++ show i) g) { tournamentStartTime = st, tournamentState = s }

ucfFilter :: LP.PublicFilter
ucfFilter = LP.defaultPublicFilter { LP.pfUpcomingFrom = Just ucfNow }

upcomingFilterSpec :: Spec
upcomingFilterSpec = describe "Upcoming filter (v0.12)" $ do

  it "keeps only future start times, soonest first, ties broken by id" $
    plIds (LP.selectPublicFiltered ucfFilter
      [ ucfT 1 Nothing (Just (ucfDay 11 10)) RegistrationOpen
      , ucfT 2 Nothing (Just (ucfDay 11 5)) RegistrationOpen
      , ucfT 3 Nothing (Just (ucfDay 11 5)) Published
      , ucfT 4 Nothing (Just (ucfDay 10 1)) RegistrationOpen
      , ucfT 5 Nothing Nothing RegistrationOpen ])
      `shouldBe` [2, 3, 1]

  it "drops Completed and Cancelled tournaments even with a future start" $
    plIds (LP.selectPublicFiltered ucfFilter
      [ ucfT 6 Nothing (Just (ucfDay 11 6)) Completed
      , ucfT 7 Nothing (Just (ucfDay 11 7)) Cancelled
      , ucfT 8 Nothing (Just (ucfDay 11 8)) InProgress ])
      `shouldBe` [8]

  it "combines with the game filter and the limit" $
    plIds (LP.selectPublicFiltered (ucfFilter { LP.pfGame = Just GameEFootball, LP.pfLimit = 2 })
      [ ucfT 10 (Just GameEFootball) (Just (ucfDay 11 3)) RegistrationOpen
      , ucfT 11 (Just GameCallOfDuty) (Just (ucfDay 11 2)) RegistrationOpen
      , ucfT 12 (Just GameEFootball) (Just (ucfDay 11 1)) RegistrationOpen
      , ucfT 13 (Just GameEFootball) (Just (ucfDay 11 4)) RegistrationOpen ])
      `shouldBe` [12, 10]

  it "counts a start exactly at the current time as upcoming" $
    plIds (LP.selectPublicFiltered ucfFilter [ ucfT 20 Nothing (Just ucfNow) RegistrationOpen ])
      `shouldBe` [20]

  it "still hides Draft and Private tournaments" $
    plIds (LP.selectPublicFiltered ucfFilter
      [ ucfT 30 Nothing (Just (ucfDay 11 1)) Draft
      , (ucfT 31 Nothing (Just (ucfDay 11 1)) RegistrationOpen) { tournamentVisibility = Private } ])
      `shouldBe` []

-- ---------------------------------------------------------------------
-- v0.12: total prize pool for the home page.
-- ---------------------------------------------------------------------

prizePoolSpec :: Spec
prizePoolSpec = describe "Prize pool stat (v0.12)" $ do

  it "sums prizes over public tournaments past Draft, excluding Cancelled" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      owner <- createTestUser "pp-owner-1"
      let withPrize n = noDetails { detailsPrize = Just n }
      a <- dtCreate owner "PP A" (withPrize 50000)
      b <- dtCreate owner "PP B" (withPrize 20000)
      _ <- dtCreate owner "PP Draft" (withPrize 7000)
      d <- dtCreate owner "PP Cancelled" (withPrize 9000)
      p <- unwrap =<< CTD.createTournamentWithDetails
             ((dtNew owner "PP Private") { newTournamentVisibility = Private }) (withPrize 4000)
      f <- dtCreate owner "PP None" noDetails
      mapM_ (\t -> unwrap =<< publishTournament owner t) [a, b, d, p, f]
      _ <- unwrap =<< cancelTournament owner d "no longer needed"
      Repo.publicStats
    case result of
      Left err -> expectationFailure (show err)
      Right s  -> statsPrizePool s `shouldBe` 70000

-- ---------------------------------------------------------------------
-- v0.12: tournament description.
-- ---------------------------------------------------------------------

descriptionSpec :: Spec
descriptionSpec = describe "Tournament description (v0.12)" $ do

  it "stores a trimmed description and reads it back" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      owner <- createTestUser "ds-owner-1"
      tid <- dtCreate owner "Described Cup" (noDetails { detailsDescription = Just "  Bring your own controller.  " })
      Repo.getTournament tid
    case result of
      Left err -> expectationFailure (show err)
      Right t  -> tournamentDescription t `shouldBe` Just "Bring your own controller."

  it "treats a blank description as none" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      owner <- createTestUser "ds-owner-2"
      tid <- dtCreate owner "Blank Desc Cup" (noDetails { detailsDescription = Just "   " })
      Repo.getTournament tid
    case result of
      Left err -> expectationFailure (show err)
      Right t  -> tournamentDescription t `shouldBe` Nothing

  it "accepts 500 characters and rejects 501, creating nothing" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      owner <- createTestUser "ds-owner-3"
      ok  <- CTD.createTournamentWithDetails (dtNew owner "Ok") (noDetails { detailsDescription = Just (replicate 500 'x') })
      bad <- CTD.createTournamentWithDetails (dtNew owner "Bad") (noDetails { detailsDescription = Just (replicate 501 'x') })
      everything <- Repo.listAllTournaments
      pure (isRight ok, bad, map tournamentName everything)
    case result of
      Left err -> expectationFailure (show err)
      Right (okRight, bad, names) -> do
        okRight `shouldBe` True
        bad `shouldBe` Left (CTD.CreateInvalidDetails (DV.DescriptionTooLong 501))
        names `shouldBe` [TournamentName "Ok"]

  it "update changes the description and logs exactly one history entry" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      owner <- createTestUser "ds-owner-4"
      tid <- dtCreate owner "Edit Desc Cup" dtDetails
      r <- UTD.updateTournamentDetails owner tid (dtDetails { detailsDescription = Just "New rules" })
      t <- Repo.getTournament tid
      changed <- dtChanged tid
      pure (r, t, changed)
    case result of
      Left err -> expectationFailure (show err)
      Right (r, t, changed) -> do
        r `shouldBe` Right ()
        tournamentDescription t `shouldBe` Just "New rules"
        changed `shouldBe` [TournamentHistory.FieldDescription]

  it "an update without a description clears it" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      owner <- createTestUser "ds-owner-5"
      tid <- dtCreate owner "Clear Desc Cup" (dtDetails { detailsDescription = Just "Old text" })
      r <- UTD.updateTournamentDetails owner tid dtDetails
      t <- Repo.getTournament tid
      changed <- dtChanged tid
      pure (r, t, changed)
    case result of
      Left err -> expectationFailure (show err)
      Right (r, t, changed) -> do
        r `shouldBe` Right ()
        tournamentDescription t `shouldBe` Nothing
        changed `shouldBe` [TournamentHistory.FieldDescription]

  it "saveTournament and publishing keep the description" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      owner <- createTestUser "ds-owner-6"
      tid <- dtCreate owner "Keep Desc Cup" (dtDetails { detailsDescription = Just "Keep me" })
      t0 <- Repo.getTournament tid
      Repo.saveTournament t0
      _ <- unwrap =<< publishTournament owner tid
      t1 <- Repo.getTournament tid
      pure (t0, t1)
    case result of
      Left err -> expectationFailure (show err)
      Right (t0, t1) -> do
        tournamentDescription t0 `shouldBe` Just "Keep me"
        tournamentDescription t1 `shouldBe` Just "Keep me"

  it "migrates a database without the description column and keeps its other data" $ do
    let path = "test/arenaos-migrate-test.db"
    exists <- doesFileExist path
    if exists then removeFile path else pure ()
    conn <- SQLite.open path
    SQLite.execute_ conn "CREATE TABLE tournaments ( id INTEGER PRIMARY KEY, name TEXT NOT NULL, organizer_name TEXT NOT NULL, owner_id INTEGER NOT NULL, format TEXT NOT NULL, state TEXT NOT NULL, visibility TEXT NOT NULL, third_place_match INTEGER NOT NULL DEFAULT 0, participant_mode TEXT NOT NULL DEFAULT 'IndividualOnly', max_participants INTEGER NOT NULL, bracket_id INTEGER, game TEXT, start_time TEXT, prize TEXT, prize_kes INTEGER )"
    SQLite.execute_ conn "INSERT INTO tournaments (id, name, organizer_name, owner_id, format, state, visibility, max_participants, game, prize_kes) VALUES (1, 'Kept Cup', 'Org', 1, 'SingleElimination', 'Draft', 'Public', 4, 'eFootball', 5000)"
    initializeSchema conn
    SQLite.close conn
    result <- runSQLiteM path (Repo.getTournament (TournamentId 1))
    removeFile path
    case result of
      Left err -> expectationFailure (show err)
      Right t -> do
        dtTriple t `shouldBe` (Just GameEFootball, Nothing, Just 5000)
        tournamentDescription t `shouldBe` Nothing

-- ---------------------------------------------------------------------
-- v0.12: changing a tournament's format (success paths).
-- ---------------------------------------------------------------------

formatChangeSpec :: Spec
formatChangeSpec = describe "Format change (v0.12)" $ do

  it "changes the format of a tournament without a bracket and logs one history entry" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      owner <- createTestUser "fc-owner-1"
      tid <- dtCreate owner "Format Cup" noDetails
      r <- UTF.updateTournamentFormat owner tid DoubleElimination
      t <- Repo.getTournament tid
      changed <- dtChanged tid
      pure (r, tournamentFormat t, changed)
    case result of
      Left err -> expectationFailure (show err)
      Right (r, f, changed) -> do
        r `shouldBe` Right ()
        f `shouldBe` DoubleElimination
        changed `shouldBe` [TournamentHistory.FieldFormat]

  it "can move between all three formats and logs each change" $ do
    result <- runSQLiteM testDbPath $ do
      setupSchema
      owner <- createTestUser "fc-owner-2"
      tid <- dtCreate owner "Format Walk Cup" noDetails
      r1 <- UTF.updateTournamentFormat owner tid DoubleElimination
      r2 <- UTF.updateTournamentFormat owner tid SingleElimination
      r3 <- UTF.updateTournamentFormat owner tid RoundRobin
      t <- Repo.getTournament tid
      changed <- dtChanged tid
      pure (r1, r2, r3, tournamentFormat t, changed)
    case result of
      Left err -> expectationFailure (show err)
      Right (r1, r2, r3, f, changed) -> do
        (r1, r2, r3) `shouldBe` (Right (), Right (), Right ())
        f `shouldBe` RoundRobin
        changed `shouldBe` [TournamentHistory.FieldFormat, TournamentHistory.FieldFormat, TournamentHistory.FieldFormat]

rkP :: String -> Participant
rkP n = Individual (Player (PlayerName n))

jrTag :: Either JRQ.JoinOrRequestError JRQ.JoinOutcome -> String
jrTag (Right JRQ.RequestPending)               = "pending"
jrTag (Right (JRQ.Joined _))                   = "joined"
jrTag (Left JRQ.JoinRequestAlreadyPending)     = "already-pending"
jrTag (Left JRQ.JoinRequestDeclined)           = "declined"
jrTag (Left (JRQ.JoinFailed _))                = "failed"

apTag :: Either JRQ.ApproveError a -> String
apTag (Right _)                          = "ok"
apTag (Left (JRQ.ApproveUnauthorized _)) = "unauthorized"
apTag (Left JRQ.ApproveFull)             = "full"
apTag (Left _)                           = "other"

dcTag :: Either JRQ.DeclineError () -> String
dcTag (Right ())                         = "ok"
dcTag (Left (JRQ.DeclineUnauthorized _)) = "unauthorized"
dcTag (Left _)                           = "other"

cqTag :: Either JRQ.CancelRequestError () -> String
cqTag (Right ())                  = "ok"
cqTag (Left JRQ.NoPendingRequest) = "none"

raTag :: Either UTRA.UpdateTournamentRequireApprovalError () -> String
raTag (Right ())                         = "ok"
raTag (Left (UTRA.Unauthorized _))       = "unauthorized"
raTag (Left (UTRA.InvalidLifecycle _))   = "lifecycle"

raNew :: UserId -> String -> NewTournament
raNew owner name = NewTournament
  { newTournamentName            = TournamentName name
  , newTournamentOrganizer       = OrganizerName "ra"
  , newTournamentFormat          = SingleElimination
  , newTournamentVisibility      = Public
  , newTournamentMaxParticipants = 8
  , newTournamentThirdPlaceMatch = False
  , newTournamentParticipantMode = IndividualOnly
  , newTournamentOwner           = owner
  }

rmTag :: Either RPC.RemoveError () -> String
rmTag (Right ())                        = "ok"
rmTag (Left (RPC.RemoveUnauthorized _)) = "unauthorized"
rmTag (Left (RPC.RemoveLifecycle _))    = "lifecycle"
rmTag (Left RPC.RemoveNotRegistered)    = "not-registered"

jnOpen :: UserId -> String -> Int -> Visibility -> SQLiteM TournamentId
jnOpen owner name mx vis = do
  tid <- dtCreate owner name noDetails
  Repo.updateTournamentMaxParticipants tid mx
  Repo.updateTournamentVisibility tid vis
  _ <- unwrap =<< publishTournament owner tid
  _ <- unwrap =<< openRegistration owner tid
  pure tid

stNow :: UTCTime
stNow = UTCTime (fromGregorian 2026 1 1) 0

stTeam :: String -> Team
stTeam n = Team (TeamName n) (Player (PlayerName (n ++ "-cap")))
  [Player (PlayerName (n ++ "-cap")), Player (PlayerName (n ++ "-p2"))]

stMake :: UserId -> String -> SQLiteM ()
stMake owner n = do
  _ <- unwrap =<< createTeam (stTeam n)
  Repo.setTeamOwner (TeamName n) owner

stOpen :: UserId -> String -> Int -> SQLiteM TournamentId
stOpen owner name mx = do
  tid <- unwrap =<< CTD.createTournamentWithDetails
           ((dtNew owner name) { newTournamentParticipantMode = SquadOnly
                               , newTournamentMaxParticipants = mx }) noDetails
  _ <- unwrap =<< publishTournament owner tid
  _ <- unwrap =<< openRegistration owner tid
  pure tid