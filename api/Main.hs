{-# LANGUAGE OverloadedStrings #-}
module Main where

import Web.Scotty
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Text.Read (readMaybe)
import Control.Monad.IO.Class (liftIO)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (SomeException, try, bracket_, evaluate)
import Control.Concurrent.QSem (QSem, newQSem, waitQSem, signalQSem)
import Data.Maybe (isJust, fromMaybe)
import System.IO (hPutStrLn, stderr)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import Data.String (fromString)
import Network.Wai.Handler.Warp (setHost, setPort, defaultSettings)
import Network.HTTP.Types
  (Status, status201, status204, status400, status401, status403, status404, status409, status429, status500)
import Data.Aeson.Types (Pair)
import Data.Aeson
  (Value(Object), object, (.=), FromJSON(..), withObject, withText, (.:), (.:?), (.!=), eitherDecode)

import Shell.Persistence.SQLite.Error (PersistenceError(..))
import Shell.Persistence.SQLite.TournamentRepository ()
import Shell.Persistence.SQLite.TournamentHistoryRepository ()
import Shell.Persistence.SQLite.ParticipantRepository ()
import Shell.Persistence.SQLite.RegistrationRepository ()
import Shell.Persistence.SQLite.BracketRepository ()
import Shell.Persistence.SQLite.MatchRepository ()
import qualified Shell.Persistence.Port as Repo

import Domain.Ids (UserId(..), TournamentId(..), BracketId(..), BracketNodeId(..))
import Domain.Match (Match(..), MatchId(..), MatchOutcome(..))
import Domain.MatchError (MatchError(..))
import Domain.Scoreable (EFootballScore, mkEFootballScore, ScoreError(..), unEFootballScore)
import Engine.Standings (Standing(..), computeStandingsWith, standingGoalDifference)
import Application.UseCases.RecordEFootballResult (recordEFootballResult, RecordEFootballResultError(..), correctEFootballResult, CorrectEFootballResultError(..))
import qualified Application.UseCases.CorrectMatchResult as Correct
import qualified Application.UseCases.SetMatchSchedule as Sched
import Data.Time (UTCTime, NominalDiffTime, getCurrentTime, addUTCTime, diffUTCTime)
import Network.Wai (remoteHost, requestHeaders)
import Control.Monad (when)
import Engine.Error (EngineError(..))
import Application.Internal.Authorization (AuthorizationError(..))
import Application.Internal.LifecycleTransition (LifecycleError(..))
import qualified Application.UseCases.PublishTournament as Publish
import qualified Application.UseCases.OpenRegistration as Open
import qualified Application.UseCases.CloseRegistration as Close
import qualified Application.UseCases.GenerateBracket as Generate
import qualified Application.UseCases.StartMatch as Start
import qualified Application.UseCases.RecordMatchResult as Record
import Data.List (find, sortOn)
import qualified Application.UseCases.GetBracket as GetB
import Domain.BracketLinks (BracketLinks, NodeDestination(..), NodeLinks(..), SlotPosition(..))
import Domain.Tournament
  ( Tournament(..), TournamentName(..), OrganizerName(..)
  , TournamentFormat(..), Visibility(..), ParticipantMode(..)
  , Game(..), TournamentDetails(..), PublicStats(..) )
import Shell.Persistence.Port (NewTournament(..))
import qualified Application.UseCases.CreateTournament as Create
import Engine.TournamentValidation
  (TournamentValidationError(..), ParticipantValidationError(..), DetailsValidationError(..))
import Domain.Registration (RegistrationId(..))
import qualified Application.UseCases.RegisterParticipant as Register
import Data.IORef (IORef, newIORef, readIORef, atomicModifyIORef')
import qualified Data.Map.Strict as Map
import qualified Data.ByteString as BS
import Numeric (showHex)
import System.Entropy (getEntropy)
import Shell.Persistence.SQLite.UserRepository ()
import Shell.Infrastructure.PasswordHasher (hashPasswordIO, verifyPasswordPure)
import qualified Application.UseCases.LoginUser as LU
import Domain.User (User(..), Username(..), Email(..), AccountStatus(..), PasswordHash(..))
import qualified Application.UseCases.RegisterUser as RU
import Engine.User (UserError(..))
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import qualified Engine.User as EU
import qualified Application.UseCases.GetTournament as GetT
import qualified Application.UseCases.ListMyTournaments as ListMine
import qualified Application.UseCases.StartTournament as StartT
import qualified Application.UseCases.CompleteTournament as Complete
import qualified Application.UseCases.CancelTournament as Cancel
import Domain.TournamentError (TournamentError(..))
import qualified Application.UseCases.ListPublicTournaments as ListPublic
import qualified Application.UseCases.UpdateTournamentThirdPlaceMatch as UTTP
import qualified Application.UseCases.UpdateTournamentRequireApproval as UTRA
import qualified Application.UseCases.UpdateTournamentName as UTN
import qualified Application.UseCases.UpdateTournamentDetails as UTD
import qualified Application.UseCases.UpdateTournamentFormat as UTF
import qualified Application.UseCases.UpdateTournamentMaxParticipants as UTM
import qualified Application.UseCases.UpdateTournamentVisibility as UTV
import qualified Application.UseCases.PauseTournament as PauseT
import qualified Application.UseCases.ResumeTournament as ResumeT
import qualified Application.UseCases.ReopenTournament as ReopenT
import Shell.Persistence.SQLite.Connection (SQLiteM, SQLiteEnv(envConnection), runSQLiteM)
import Shell.Persistence.SQLite.Schema (initializeSchema)
import Control.Monad.Reader (ask)
import Domain.Bracket (Bracket(..), BracketNode(..), MatchSlot(..))
import Shell.Persistence.SQLite.EFootballScoreRepository ()
import Shell.Persistence.SQLite.JoinRequestRepository ()
import Shell.Persistence.SQLite.NotificationRepository ()
import qualified Application.UseCases.JoinRequests as JRQ
import Domain.JoinRequest (JoinRequestStatus(..))
import qualified Domain.TournamentHistory as TH
import qualified Domain.Notification as Notif
import qualified Application.UseCases.GetRankings as GRK
import qualified Engine.Rankings as Rk
import qualified Application.UseCases.GetPlayers as GPL
import qualified Engine.Players as Pl
import Domain.Participant (Participant(..), Player(..), PlayerName(..), Team(..), TeamName(..))
import qualified Application.UseCases.CreateTeam as CT
import Application.UseCases.CreateTeam (createTeam, CreateTeamError(..))
import Application.UseCases.CreateTeam (createTeam, CreateTeamError(..))


defaultDbPath :: FilePath
defaultDbPath = "arenaos-dev.db"

envOr :: String -> String -> IO String
envOr name def = do
  v <- lookupEnv name
  pure (case v of
    Just s | not (null s) -> s
    _                     -> def)

readIntEnv :: String -> Int -> IO Int
readIntEnv name def = do
  v <- envOr name (show def)
  case readMaybe v of
    Just n | n > 0 -> pure n
    _ -> do
      hPutStrLn stderr ("invalid " ++ name ++ ": " ++ v)
      exitFailure

readPort :: IO Int
readPort = do
  v <- envOr "PORT" "3000"
  case readMaybe v of
    Just p | p > 0 && p < 65536 -> pure p
    _ -> do
      hPutStrLn stderr ("invalid PORT: " ++ v)
      exitFailure

-- ===== Errors =====

data ApiError = ApiError Status Text Text Value

sendError :: ApiError -> ActionM ()
sendError (ApiError st code msg details) = do
  status st
  json (object ["error" .= object
    ["code" .= code, "message" .= msg, "details" .= details]])

internalError :: ApiError
internalError = ApiError status500 "INTERNAL_ERROR" "Internal error" (object [])

invalidBody :: String -> ApiError
invalidBody reason = ApiError status400 "INVALID_BODY"
  "Request body is invalid" (object ["reason" .= reason])

fromAuthorization :: AuthorizationError -> ApiError
fromAuthorization NotTournamentOwner =
  ApiError status403 "NOT_TOURNAMENT_OWNER" "Only the tournament owner can do this" (object [])
fromAuthorization NotAdministrator =
  ApiError status403 "NOT_ADMINISTRATOR" "Administrator role required" (object [])
fromAuthorization NotAuthorizedToView =
  ApiError status404 "NOT_FOUND" "Resource not found" (object [])

fromLifecycle :: LifecycleError -> ApiError
fromLifecycle (InvalidTransition cur expected) =
  ApiError status409 "INVALID_TRANSITION" "Tournament is not in the required state"
    (object ["current" .= show cur, "expected" .= show expected])
fromLifecycle (ForbiddenState cur) =
  ApiError status409 "FORBIDDEN_STATE" "Not allowed in the current state"
    (object ["current" .= show cur])

fromPersistence :: PersistenceError -> ApiError
fromPersistence (NotFound _) =
  ApiError status404 "NOT_FOUND" "Resource not found" (object [])
fromPersistence (ConstraintViolation _) =
  ApiError status409 "CONSTRAINT_VIOLATION" "Request conflicts with existing data" (object [])
fromPersistence _ = internalError

fromEngine :: EngineError -> ApiError
fromEngine (TooFewParticipants n) =
  ApiError status409 "TOO_FEW_PARTICIPANTS"
    "Not enough participants to build a bracket" (object ["count" .= n])
fromEngine (DuplicateParticipant _) =
  ApiError status409 "DUPLICATE_PARTICIPANT"
    "A participant is registered more than once" (object [])
fromEngine (ParticipantModeMismatch _) =
  ApiError status409 "PARTICIPANT_MODE_MISMATCH"
    "Individuals and teams cannot be mixed" (object [])

fromGenerate :: Generate.GenerateBracketError -> ApiError
fromGenerate (Generate.Unauthorized a)        = fromAuthorization a
fromGenerate (Generate.InvalidLifecycle l)    = fromLifecycle l
fromGenerate (Generate.BracketAlreadyExists b) =
  ApiError status409 "BRACKET_ALREADY_EXISTS"
    "A bracket has already been generated for this tournament"
    (object ["bracketId" .= unBracketId b])
fromGenerate (Generate.UnsupportedFormat _)   = internalError
fromGenerate (Generate.InvalidBracket e)      = fromEngine e
fromGenerate (Generate.LinkDerivationFailed _) = internalError

fromMatchError :: MatchError -> ApiError
fromMatchError (MatchNotScheduled s) =
  ApiError status409 "MATCH_NOT_SCHEDULED" "Match is not in the Scheduled state"
    (object ["current" .= show s])
fromMatchError (MatchNotInProgress s) =
  ApiError status409 "MATCH_NOT_IN_PROGRESS" "Match is not in progress"
    (object ["current" .= show s])
fromMatchError (OutcomeNotAdvanceable _) =
  ApiError status409 "OUTCOME_NOT_ADVANCEABLE" "This outcome cannot advance the bracket"
    (object [])
fromMatchError (ParticipantNotInMatch _) = internalError

fromStart :: Start.StartMatchError -> ApiError
fromStart (Start.Unauthorized a)     = fromAuthorization a
fromStart (Start.InvalidLifecycle l) = fromLifecycle l
fromStart (Start.InvalidMatch e)     = fromMatchError e

fromRecord :: Record.RecordMatchResultError -> ApiError
fromRecord (Record.Unauthorized a)     = fromAuthorization a
fromRecord (Record.InvalidLifecycle l) = fromLifecycle l
fromRecord (Record.InvalidMatch e)     = fromMatchError e
fromRecordEFootball :: RecordEFootballResultError -> ApiError
fromRecordEFootball (MatchResultError e) = fromRecord e

fromCorrect :: Correct.CorrectMatchResultError -> ApiError
fromCorrect (Correct.Unauthorized a)     = fromAuthorization a
fromCorrect (Correct.InvalidLifecycle l) = fromLifecycle l
fromCorrect Correct.TournamentAlreadyCompleted =
  ApiError status409 "TOURNAMENT_ALREADY_COMPLETED"
    "The tournament is completed; reopen it before correcting results" (object [])
fromCorrect (Correct.UnsupportedFormatForCorrection f) =
  ApiError status409 "CORRECTION_UNSUPPORTED_FORMAT"
    "Results cannot be corrected in this tournament format"
    (object ["format" .= show f])
fromCorrect (Correct.SourceMatchNotCompleted s) =
  ApiError status409 "MATCH_NOT_COMPLETED" "Only a completed match can be corrected"
    (object ["current" .= show s])
fromCorrect (Correct.CorrectedParticipantNotInMatch _) =
  ApiError status400 "PARTICIPANT_NOT_IN_MATCH"
    "The corrected winner is not a competitor in this match" (object [])
fromCorrect (Correct.DownstreamMatchStarted mid) =
  ApiError status409 "DOWNSTREAM_MATCH_STARTED"
    "A match that depends on this result has already started"
    (object ["matchId" .= unMatchId mid])
fromCorrect (Correct.SourceMatchOutcomeInvalid mid) =
  ApiError status409 "MATCH_OUTCOME_INVALID"
    "The match's stored outcome cannot be corrected"
    (object ["matchId" .= unMatchId mid])
fromCorrect (Correct.CorrectedOutcomeNotAdvanceable _) =
  ApiError status409 "OUTCOME_NOT_ADVANCEABLE" "This outcome cannot advance the bracket"
    (object [])
fromCorrect (Correct.CorrectionIntegrityViolation _) = internalError
fromCorrect (Correct.GF1ResetNotRestorable mid) =
  ApiError status409 "GF1_RESET_NOT_RESTORABLE"
    "This final was decided without a reset and cannot be changed back"
    (object ["matchId" .= unMatchId mid])
fromCorrect Correct.BracketLinksUnavailable =
  ApiError status409 "BRACKET_LINKS_UNAVAILABLE"
    "This tournament's bracket was generated before result correction was supported, so its results cannot be corrected"
    (object [])

fromCorrectEFootball :: CorrectEFootballResultError -> ApiError
fromCorrectEFootball (EFootballCorrectionFailed e) = fromCorrect e

fromSetSchedule :: Sched.SetMatchScheduleError -> ApiError
fromSetSchedule (Sched.Unauthorized a)     = fromAuthorization a
fromSetSchedule (Sched.InvalidLifecycle l) = fromLifecycle l
fromSetSchedule (Sched.InvalidMatch e)     = fromMatchError e



-- ===== JSON out =====

playerStr :: Player -> String
playerStr (Player (PlayerName n)) = n

participantJson :: Participant -> Value
participantJson (Individual p) =
  object ["type" .= ("Individual" :: Text), "player" .= playerStr p]
participantJson (Squad t) =
  object [ "type" .= ("Squad" :: Text)
         , "team" .= object
             [ "name"    .= unTeamName (teamName t)
             , "captain" .= playerStr (teamCaptain t)
             , "members" .= map playerStr (teamMembers t) ] ]

outcomeJson :: Match -> MatchOutcome -> Value
outcomeJson m o = case o of
  Winner p           -> withSide "Winner" p
  Forfeit p          -> withSide "Forfeit" p
  Disqualification p -> withSide "Disqualification" p
  Draw               -> object ["type" .= ("Draw" :: Text)]
  NoContest          -> object ["type" .= ("NoContest" :: Text)]
  where
    withSide t p = object ["type" .= (t :: Text), "winner" .= sideOf p]
    sideOf p | p == matchCompetitorA m = "A" :: Text
             | otherwise               = "B"

matchJson :: Match -> Value
matchJson m = object
  [ "matchId"        .= unMatchId (matchId m)
  , "tournamentId"   .= unTournamentId (matchTournament m)
  , "bracketId"      .= unBracketId (matchBracket m)
  , "nodeId"         .= unBracketNodeId (matchBracketNode m)
  , "competitorA"    .= participantJson (matchCompetitorA m)
  , "competitorB"    .= participantJson (matchCompetitorB m)
  , "status"         .= T.pack (show (matchStatus m))
  , "outcome"        .= fmap (outcomeJson m) (matchOutcome m)
  , "scheduledStart" .= matchScheduledStart m
  ]

-- ===== JSON in =====

data Side = SideA | SideB

instance FromJSON Side where
  parseJSON = withText "winner" $ \s -> case s of
    "A" -> pure SideA
    "B" -> pure SideB
    _   -> fail "winner must be \"A\" or \"B\""

data OutcomeReq
  = ReqWinner Side | ReqForfeit Side | ReqDisqualification Side
  | ReqDraw | ReqNoContest

instance FromJSON OutcomeReq where
  parseJSON = withObject "outcome" $ \o -> do
    t <- o .: "type"
    case (t :: Text) of
      "Winner"           -> ReqWinner <$> o .: "winner"
      "Forfeit"          -> ReqForfeit <$> o .: "winner"
      "Disqualification" -> ReqDisqualification <$> o .: "winner"
      "Draw"             -> pure ReqDraw
      "NoContest"        -> pure ReqNoContest
      _                  -> fail "unknown outcome type"

toOutcome :: Match -> OutcomeReq -> MatchOutcome
toOutcome m r = case r of
  ReqWinner s           -> Winner (pick s)
  ReqForfeit s          -> Forfeit (pick s)
  ReqDisqualification s -> Disqualification (pick s)
  ReqDraw               -> Draw
  ReqNoContest          -> NoContest
  where
    pick SideA = matchCompetitorA m
    pick SideB = matchCompetitorB m

getBracketWithScores
  :: Maybe UserId -> TournamentId
  -> SQLiteM (Either GetB.GetBracketError (GetB.BracketView, Map.Map MatchId (Int, Int)))
getBracketWithScores mu tid = do
  result <- GetB.getBracket mu tid
  case result of
    Left err -> pure (Left err)
    Right v  -> do
      found <- traverse
        (\m -> fmap ((,) (matchId m)) <$> Repo.getEFootballScore (matchId m))
        (GetB.viewMatches v)
      let scores = Map.fromList
            [ (mid, (unEFootballScore a, unEFootballScore b)) | Just (mid, (a, b)) <- found ]
      pure (Right (v, scores))
recordViaApi :: UserId -> MatchId -> OutcomeReq
             -> SQLiteM (Either Record.RecordMatchResultError Match)
recordViaApi uid mid req = do
  m <- Repo.getMatch mid
  Record.recordMatchResult uid mid (toOutcome m req)

correctViaApi :: UserId -> MatchId -> OutcomeReq
              -> SQLiteM (Either Correct.CorrectMatchResultError Match)
correctViaApi uid mid req = do
  m <- Repo.getMatch mid
  Correct.correctMatchResult uid mid (toOutcome m req)

slotJson :: MatchSlot -> Value
slotJson (Filled p) =
  object ["type" .= ("Filled" :: Text), "participant" .= participantJson p]
slotJson (AwaitingWinnerOf n) =
  object ["type" .= ("AwaitingWinnerOf" :: Text), "node" .= unBracketNodeId n]
slotJson (AwaitingLoserOf n) =
  object ["type" .= ("AwaitingLoserOf" :: Text), "node" .= unBracketNodeId n]
slotJson ByeSlot =
  object ["type" .= ("Bye" :: Text)]

slotText :: SlotPosition -> Text
slotText SlotA = "A"
slotText SlotB = "B"

destinationJson :: NodeDestination -> Value
destinationJson (NodeDestination d pos) =
  object [ "node" .= unBracketNodeId d, "slot" .= slotText pos ]

nodeJson :: Map.Map MatchId (Int, Int) -> Maybe BracketLinks -> [Match] -> BracketNode -> Value
nodeJson scores mLinks matches n = object . (++ linkPairs) $
  [ "nodeId" .= unBracketNodeId (nodeId n)
  , "round"  .= nodeRound n
  , "stage"  .= T.pack (show (nodeStage n))
  , "slotA"  .= slotJson (nodeSlotA n)
  , "slotB"  .= slotJson (nodeSlotB n)
  , "match"  .= fmap matchJson (find (\m -> matchBracketNode m == nodeId n) matches)
  , "score"  .= (find (\m -> matchBracketNode m == nodeId n) matches >>= \m -> fmap (\(a, b) -> object ["a" .= a, "b" .= b]) (Map.lookup (matchId m) scores))
  ]
  where
    -- only when the bracket has stored links; otherwise the fields are absent on every node
    linkPairs = case mLinks of
      Nothing    -> []
      Just links ->
        let l = lookup (nodeId n) links
        in [ "winnerTo" .= fmap destinationJson (l >>= linkWinnerTo)
           , "loserTo"  .= fmap destinationJson (l >>= linkLoserTo) ]

standingsJson :: Map.Map MatchId (Int, Int) -> Tournament -> [Match] -> Maybe [Value]
standingsJson scores t matches
  | tournamentFormat t == RoundRobin =
      Just [ object [ "participant"    .= participantJson (standingParticipant s)
                    , "points"         .= standingPoints s
                    , "goalsFor"       .= standingGoalsFor s
                    , "goalsAgainst"   .= standingGoalsAgainst s
                    , "goalDifference" .= standingGoalDifference s ]
           | s <- computeStandingsWith (Map.toList scores) matches ]
  | otherwise = Nothing
bracketViewJson :: Map.Map MatchId (Int, Int) -> GetB.BracketView -> Value
bracketViewJson scores v = object
  [ "tournamentId"     .= unTournamentId (tournamentId t)
  , "format"           .= T.pack (show (tournamentFormat t))
  , "bracketId"        .= fmap unBracketId (tournamentBracket t)
  , "thirdPlaceNodeId" .= fmap unBracketNodeId (bracketThirdPlaceNodeId (GetB.viewBracket v))
  , "grandFinalNodeId" .= fmap unBracketNodeId (bracketGF1NodeId (GetB.viewBracket v))
  , "resetNodeId"      .= fmap unBracketNodeId (bracketResetNodeId (GetB.viewBracket v))
  , "standings"        .= standingsJson scores t (GetB.viewMatches v)
  , "unscoredMatches" .= unscoredMatches
  , "linksAvailable"   .= maybe False (const True) (GetB.viewLinks v)
  , "nodes"            .= map (nodeJson scores (GetB.viewLinks v) (GetB.viewMatches v)) sortedNodes
  ]
  where
    t = GetB.viewTournament v
    unscoredMatches = length [ m | m <- GetB.viewMatches v, maybe False (const True) (matchOutcome m), not (Map.member (matchId m) scores) ]
    sortedNodes = sortOn (\n -> (nodeRound n, unBracketNodeId (nodeId n)))
                         (GetB.viewNodes v)

fromGetBracket :: GetB.GetBracketError -> ApiError
fromGetBracket (GetB.Unauthorized a)    = fromAuthorization a
fromGetBracket GetB.BracketNotGenerated =
  ApiError status404 "BRACKET_NOT_GENERATED"
    "No bracket has been generated for this tournament yet" (object [])

data ScheduleReq = ScheduleReq (Maybe UTCTime)

instance FromJSON ScheduleReq where
  parseJSON = withObject "schedule" $ \o -> ScheduleReq <$> o .: "start"

data EFootballResultReq = EFootballResultReq EFootballScore EFootballScore

instance FromJSON EFootballResultReq where
  parseJSON = withObject "efootball-result" $ \o -> do
    rawA <- o .: "scoreA"
    rawB <- o .: "scoreB"
    case (mkEFootballScore rawA, mkEFootballScore rawB) of
      (Right a, Right b) -> pure (EFootballResultReq a b)
      (Left (NegativeScore n), _) -> fail ("scoreA/scoreB must not be negative, got " ++ show n)
      (_, Left (NegativeScore n)) -> fail ("scoreA/scoreB must not be negative, got " ++ show n)

data CreateTeamReq = CreateTeamReq
  { reqTeamName :: String
  , reqCaptain  :: String
  , reqMembers  :: [String]
  }

instance FromJSON CreateTeamReq where
  parseJSON = withObject "team" $ \o -> do
    n   <- o .: "name"
    cap <- o .: "captain"
    ms  <- o .: "members"
    pure (CreateTeamReq n cap ms)

toTeam :: CreateTeamReq -> Team
toTeam r = Team
  { teamName    = TeamName (reqTeamName r)
  , teamCaptain = Player (PlayerName (reqCaptain r))
  , teamMembers = map (Player . PlayerName) (reqMembers r)
  }

teamJson :: Team -> Value
teamJson t = object
  [ "name"    .= unTeamName (teamName t)
  , "captain" .= playerStr (teamCaptain t)
  , "members" .= map playerStr (teamMembers t)
  ]

fromCreateTeam :: CreateTeamError -> ApiError
fromCreateTeam CaptainNotInMembers =
  ApiError status400 "VALIDATION_FAILED"
    "The captain must be one of the team's members" (object ["field" .= ("captain" :: Text)])
fromCreateTeam EmptyTeamName =
  ApiError status400 "VALIDATION_FAILED"
    "Team name must not be blank" (object ["field" .= ("name" :: Text)])
fromCreateTeam EmptyPlayerName =
  ApiError status400 "VALIDATION_FAILED"
    "Player names must not be blank" (object ["field" .= ("members" :: Text)])
fromCreateTeam DuplicateMemberNames =
  ApiError status400 "VALIDATION_FAILED"
    "A player is listed more than once" (object ["field" .= ("members" :: Text)])
fromCreateTeam (TeamNameAlreadyExists (TeamName n)) =
  ApiError status409 "TEAM_NAME_TAKEN"
    "A team with that name already exists" (object ["name" .= n])


data CreateReq = CreateReq
  { reqName            :: String
  , reqOrganizer       :: String
  , reqFormat          :: TournamentFormat
  , reqVisibility      :: Visibility
  , reqMaxPlayers      :: Int
  , reqThirdPlaceMatch :: Bool
  , reqParticipantMode :: ParticipantMode
  , reqRequireApproval :: Bool
  , reqDetails         :: TournamentDetails
  }

instance FromJSON CreateReq where
  parseJSON = withObject "tournament" $ \o -> do
    n   <- o .: "name"
    org <- o .: "organizer"
    f   <- o .: "format"
    v   <- o .: "visibility"
    m   <- o .: "maxParticipants"
    tp  <- o .:? "thirdPlaceMatch" .!= False
    pm  <- o .:? "participantMode" .!= ("IndividualOnly" :: Text)
    fmt <- case (f :: Text) of
      "SingleElimination" -> pure SingleElimination
      "DoubleElimination" -> pure DoubleElimination
      "RoundRobin"        -> pure RoundRobin
      _ -> fail "format must be SingleElimination, DoubleElimination or RoundRobin"
    vis <- case (v :: Text) of
      "Public"  -> pure Public
      "Private" -> pure Private
      _ -> fail "visibility must be Public or Private"
    mode <- case pm of
      "IndividualOnly" -> pure IndividualOnly
      "SquadOnly"      -> pure SquadOnly
      _ -> fail "participantMode must be IndividualOnly or SquadOnly"
    DetailsReq det <- parseJSON (Object o)
    ra  <- o .:? "requireApproval" .!= False
    pure (CreateReq n org fmt vis m tp mode ra det)
  --  pure (CreateReq n org fmt vis m tp)

toNewTournament :: UserId -> CreateReq -> NewTournament
toNewTournament uid r = NewTournament
  { newTournamentName            = TournamentName (reqName r)
  , newTournamentOrganizer       = OrganizerName (reqOrganizer r)
  , newTournamentFormat          = reqFormat r
  , newTournamentVisibility      = reqVisibility r
  , newTournamentMaxParticipants = reqMaxPlayers r
  , newTournamentOwner           = uid
  , newTournamentThirdPlaceMatch = reqThirdPlaceMatch r
  , newTournamentParticipantMode = reqParticipantMode r
  }

tournamentJson :: Tournament -> Value
tournamentJson t = object (tournamentPairs t)

tournamentJsonCounted :: Int -> Tournament -> Value
tournamentJsonCounted n t = object (("registeredCount" .= n) : tournamentPairs t)

countFor :: [(TournamentId, Int)] -> Tournament -> Int
countFor cs t = fromMaybe 0 (lookup (tournamentId t) cs)

gameText :: Game -> Text
gameText GameEFootball  = "eFootball"
gameText GamePubgMobile = "PubgMobile"
gameText GameCallOfDuty = "CallOfDuty"
gameText GameOther      = "Other"

gameFromText :: Text -> Maybe Game
gameFromText "eFootball"  = Just GameEFootball
gameFromText "PubgMobile" = Just GamePubgMobile
gameFromText "CallOfDuty" = Just GameCallOfDuty
gameFromText "Other"      = Just GameOther
gameFromText _            = Nothing

-- Absent or null fields mean "none". Shared by create and PUT /details.
newtype DetailsReq = DetailsReq TournamentDetails

instance FromJSON DetailsReq where
  parseJSON = withObject "details" $ \o -> do
    mg <- o .:? "game"
    g <- case mg of
      Nothing -> pure Nothing
      Just txt -> case gameFromText txt of
        Just x  -> pure (Just x)
        Nothing -> fail "game must be eFootball, PubgMobile, CallOfDuty or Other"
    st <- o .:? "startTime"
    pz <- o .:? "prize"
    ds <- o .:? "description"
    rd <- o .:? "registrationDeadline"
    pure (DetailsReq (TournamentDetails g st pz ds rd))

-- ?q= (name contains), ?game= (eFootball | PubgMobile | CallOfDuty | Other), ?limit= (1..100)
parseListFilter :: UTCTime -> Maybe Text -> Maybe Text -> Maybe Text -> Maybe Text -> Either ApiError ListPublic.PublicFilter
parseListFilter now mq mg ml mu = do
  game <- case fmap T.strip mg of
    Nothing -> Right Nothing
    Just g
      | T.null g  -> Right Nothing
      | otherwise -> maybe (Left (badParam "game")) (Right . Just) (gameFromText g)
  limit <- case fmap T.strip ml of
    Nothing -> Right (ListPublic.pfLimit ListPublic.defaultPublicFilter)
    Just l -> case readMaybe (T.unpack l) of
      Just n | n >= 1 -> Right (min 100 n)
      _               -> Left (badParam "limit")
  upcoming <- case fmap T.strip mu of
    Nothing -> Right Nothing
    Just u
      | T.null u || u == "0" || u == "false" -> Right Nothing
      | u == "1" || u == "true"              -> Right (Just now)
      | otherwise                            -> Left (badParam "upcoming")
  let q = case fmap T.strip mq of
        Just s | not (T.null s) -> Just (T.unpack s)
        _                       -> Nothing
  Right (ListPublic.PublicFilter q game limit upcoming)
  where
    badParam :: Text -> ApiError
    badParam f = ApiError status400 "VALIDATION_FAILED" "Invalid query parameter"
      (object ["field" .= f])

statsJson :: PublicStats -> Value
statsJson s = object
  [ "tournaments"       .= statsTournaments s
  , "activeTournaments" .= statsActiveTournaments s
  , "players"           .= statsPlayers s
  , "teams"             .= statsTeams s
  , "prizePool"         .= statsPrizePool s
  , "byGame"            .= [ object ["game" .= gameText g, "count" .= n] | (g, n) <- statsByGame s ]
  ]

parseRankingsQuery :: Maybe Text -> Maybe Text -> Either ApiError (Maybe Game, Int)
parseRankingsQuery mg ml = do
  game <- case fmap T.strip mg of
    Nothing -> Right Nothing
    Just g
      | T.null g  -> Right Nothing
      | otherwise -> maybe (Left (bad "game")) (Right . Just) (gameFromText g)
  limitN <- case fmap T.strip ml of
    Nothing -> Right 5
    Just l -> case readMaybe (T.unpack l) of
      Just n | n >= 1 -> Right (min 50 n)
      _               -> Left (bad "limit")
  Right (game, limitN)
  where
    bad :: Text -> ApiError
    bad f = ApiError status400 "VALIDATION_FAILED" "Invalid query parameter"
      (object ["field" .= f])

parsePlayersQuery :: Maybe Text -> Maybe Text -> Either ApiError (Maybe String, Int)
parsePlayersQuery mq ml = do
  limitN <- case fmap T.strip ml of
    Nothing -> Right 50
    Just l -> case readMaybe (T.unpack l) of
      Just n | n >= 1 -> Right (min 100 n)
      _               -> Left badLimit
  let q = case fmap T.strip mq of
        Just s | not (T.null s) -> Just (T.unpack s)
        _                       -> Nothing
  Right (q, limitN)
  where
    badLimit = ApiError status400 "VALIDATION_FAILED" "Invalid query parameter"
      (object ["field" .= ("limit" :: Text)])

playerSummaryJson :: Pl.PlayerSummary -> Value
playerSummaryJson s = object
  [ "name"        .= Pl.psName s
  , "tournaments" .= Pl.psEntered s
  , "titles"      .= Pl.psTitles s
  , "wins"        .= Pl.psWins s
  ]

playerProfileJson :: GPL.PlayerProfile -> Value
playerProfileJson p = object
  [ "name"        .= Pl.psName s
  , "tournaments" .= Pl.psEntered s
  , "titles"      .= Pl.psTitles s
  , "wins"        .= Pl.psWins s
  , "history"     .= [ object ["tournament" .= tournamentJson t, "champion" .= c] | (t, c) <- GPL.ppHistory p ]
  ]
  where s = GPL.ppSummary p

rankingJson :: (Int, Rk.RankingEntry) -> Value
rankingJson (r, e) = object
  [ "rank"   .= r
  , "player" .= Rk.rankPlayer e
  , "titles" .= Rk.rankTitles e
  , "wins"   .= Rk.rankWins e
  ]

notificationKindText :: Notif.NotificationKind -> Text
notificationKindText k = case k of
  Notif.NoteJoinRequested     -> "JoinRequested"
  Notif.NoteRequestApproved   -> "RequestApproved"
  Notif.NoteRequestDeclined   -> "RequestDeclined"
  Notif.NoteTournamentStarted -> "TournamentStarted"

notificationJson :: Notif.Notification -> Value
notificationJson n = object
  [ "id"             .= Notif.notificationId n
  , "kind"           .= notificationKindText (Notif.notificationKind n)
  , "tournamentId"   .= unTournamentId (Notif.notificationTournamentId n)
  , "tournamentName" .= Notif.notificationTournamentName n
  , "detail"         .= Notif.notificationDetail n
  , "at"             .= Notif.notificationAt n
  , "read"           .= Notif.notificationRead n
  ]

activityEventText :: TH.TournamentHistoryEvent -> Text
activityEventText e = case e of
  TH.TournamentPublished   -> "Published"
  TH.RegistrationOpened    -> "RegistrationOpened"
  TH.TournamentStarted     -> "Started"
  TH.TournamentCompleted   -> "Completed"
  TH.TournamentCancelled _ -> "Cancelled"
  TH.TournamentReopened _  -> "Reopened"
  _                        -> "Other"

activityJson :: TH.ActivityItem -> Value
activityJson a = object
  [ "tournamentId" .= unTournamentId (TH.activityTournamentId a)
  , "name"         .= TH.activityTournamentName a
  , "event"        .= activityEventText (TH.activityEvent a)
  , "at"           .= TH.activityAt a
  ]

tournamentPairs :: Tournament -> [Pair]
tournamentPairs t =
  [ "game"      .= fmap gameText (tournamentGame t)
  , "startTime" .= tournamentStartTime t
  , "prize"     .= tournamentPrize t
  , "description" .= tournamentDescription t
  , "tournamentId"    .= unTournamentId (tournamentId t)
  , "name"            .= unTournamentName (tournamentName t)
  , "organizer"       .= unOrganizerName (tournamentOrganizer t)
  , "format"          .= T.pack (show (tournamentFormat t))
  , "state"           .= T.pack (show (tournamentState t))
  , "visibility"      .= T.pack (show (tournamentVisibility t))
  , "maxParticipants" .= tournamentMaxParticipants t
  , "thirdPlaceMatch" .= tournamentThirdPlaceMatch t
  , "requireApproval" .= tournamentRequireApproval t
  , "registrationDeadline" .= tournamentRegistrationDeadline t
  , "participantMode" .= T.pack (show (tournamentParticipantMode t))
  , "bracketId"       .= fmap unBracketId (tournamentBracket t)
  ]



tournamentViewJson :: GetT.TournamentView -> Value
tournamentViewJson v = object
  [ "tournament"    .= tournamentJsonCounted (length (GetT.tvParticipants v)) (GetT.tvTournament v)
  , "participants"  .= map participantJson (GetT.tvParticipants v)
  , "viewerIsOwner" .= GetT.tvViewerIsOwner v
  , "viewerIsRegistered" .= GetT.tvViewerIsRegistered v
  , "viewerRequestStatus" .= fmap requestStatusText (GetT.tvViewerRequestStatus v)
  ]

fromJoin :: Register.JoinTournamentError -> ApiError
fromJoin (Register.JoinNotVisible a) = fromAuthorization a
fromJoin (Register.JoinLifecycle l)  = fromLifecycle l
fromJoin Register.JoinSquadOnly =
  ApiError status409 "SQUAD_ONLY"
    "This tournament is for teams. Ask the organizer to register your team" (object [])
fromJoin Register.JoinAlreadyJoined =
  ApiError status409 "ALREADY_REGISTERED" "You are already registered" (object [])
fromJoin Register.JoinNameTaken =
  ApiError status409 "NAME_TAKEN"
    "A player with your name is already registered. Ask the organizer" (object [])
fromJoin Register.JoinFull =
  ApiError status409 "REGISTRATION_CAPACITY_REACHED" "The tournament is full" (object [])
fromJoin Register.JoinAccountMissing = unauthenticated

fromJoinOrRequest :: JRQ.JoinOrRequestError -> ApiError
fromJoinOrRequest JRQ.JoinDeadlinePassed =
  ApiError status409 "REGISTRATION_DEADLINE_PASSED"
    "The registration deadline has passed" (object [])
fromJoinOrRequest (JRQ.JoinFailed e) = fromJoin e
fromJoinOrRequest JRQ.JoinRequestAlreadyPending =
  ApiError status409 "REQUEST_PENDING"
    "Your request is waiting for the organizer's approval" (object [])
fromJoinOrRequest JRQ.JoinRequestDeclined =
  ApiError status403 "REQUEST_DECLINED"
    "The organizer declined your request to join this tournament" (object [])

fromCancelRequest :: JRQ.CancelRequestError -> ApiError
fromCancelRequest JRQ.NoPendingRequest =
  ApiError status404 "NO_PENDING_REQUEST"
    "You have no pending request for this tournament" (object [])

requestStatusText :: JoinRequestStatus -> Text
requestStatusText JoinPending  = "Pending"
requestStatusText JoinApproved = "Approved"
requestStatusText JoinDeclined = "Declined"

newtype TargetUserReq = TargetUserReq Int

instance FromJSON TargetUserReq where
  parseJSON = withObject "target" $ \o -> TargetUserReq <$> o .: "userId"

entryJson :: JRQ.JoinRequestEntry -> Value
entryJson (JRQ.JoinRequestEntry (UserId u) name st) =
  object [ "userId" .= u, "username" .= name, "status" .= requestStatusText st ]

fromApprove :: JRQ.ApproveError -> ApiError
fromApprove (JRQ.ApproveUnauthorized a) = fromAuthorization a
fromApprove (JRQ.ApproveLifecycle l)    = fromLifecycle l
fromApprove JRQ.ApproveNoRequest =
  ApiError status404 "NO_REQUEST" "There is no request from that player" (object [])
fromApprove JRQ.ApproveAlreadyJoined =
  ApiError status409 "ALREADY_REGISTERED" "That player is already registered" (object [])
fromApprove JRQ.ApproveNameTaken =
  ApiError status409 "NAME_TAKEN" "A player with that name is already registered" (object [])
fromApprove JRQ.ApproveFull =
  ApiError status409 "REGISTRATION_CAPACITY_REACHED" "The tournament is full" (object [])
fromApprove JRQ.ApproveAccountMissing =
  ApiError status404 "NOT_FOUND" "Resource not found" (object [])

fromDecline :: JRQ.DeclineError -> ApiError
fromDecline (JRQ.DeclineUnauthorized a) = fromAuthorization a
fromDecline (JRQ.DeclineLifecycle l)    = fromLifecycle l
fromDecline JRQ.DeclineNoRequest =
  ApiError status404 "NO_REQUEST" "There is no request from that player" (object [])

fromListRequests :: JRQ.ListRequestsError -> ApiError
fromListRequests (JRQ.ListUnauthorized a) = fromAuthorization a

fromWithdraw :: Register.WithdrawError -> ApiError
fromWithdraw (Register.WithdrawLifecycle l) = fromLifecycle l
fromWithdraw Register.WithdrawNotRegistered =
  ApiError status404 "NOT_REGISTERED" "You are not registered for this tournament" (object [])

fromRemove :: Register.RemoveError -> ApiError
fromRemove (Register.RemoveUnauthorized a) = fromAuthorization a
fromRemove (Register.RemoveLifecycle l)    = fromLifecycle l
fromRemove Register.RemoveNotRegistered =
  ApiError status404 "NOT_REGISTERED" "That participant is not registered for this tournament" (object [])

newtype JoinTeamReq = JoinTeamReq String

instance FromJSON JoinTeamReq where
  parseJSON = withObject "joinTeam" $ \o -> JoinTeamReq <$> o .: "teamName"

fromJoinTeam :: Register.JoinTeamError -> ApiError
fromJoinTeam (Register.JoinTeamNotVisible a) = fromAuthorization a
fromJoinTeam (Register.JoinTeamLifecycle l)  = fromLifecycle l
fromJoinTeam Register.JoinTeamIndividualOnly =
  ApiError status409 "INDIVIDUAL_ONLY" "This tournament is for individual players" (object [])
fromJoinTeam Register.JoinTeamApprovalRequired =
  ApiError status409 "APPROVAL_REQUIRED"
    "This tournament needs the organizer's approval. Ask the organizer to register your team" (object [])
fromJoinTeam Register.JoinTeamDeadlinePassed =
  ApiError status409 "REGISTRATION_DEADLINE_PASSED" "The registration deadline has passed" (object [])
fromJoinTeam Register.JoinTeamNotFound =
  ApiError status404 "NOT_FOUND" "No team with that name" (object [])
fromJoinTeam Register.JoinTeamNotOwner =
  ApiError status403 "NOT_TEAM_OWNER" "You can only register teams you created" (object [])
fromJoinTeam Register.JoinTeamAlreadyJoined =
  ApiError status409 "ALREADY_REGISTERED" "You are already registered" (object [])
fromJoinTeam Register.JoinTeamAlreadyRegistered =
  ApiError status409 "ALREADY_REGISTERED" "This team is already registered" (object [])
fromJoinTeam Register.JoinTeamFull =
  ApiError status409 "REGISTRATION_CAPACITY_REACHED" "The tournament is full" (object [])

fromGetTournament :: GetT.GetTournamentError -> ApiError
fromGetTournament (GetT.Unauthorized a) = fromAuthorization a

newtype CancelReq = CancelReq String

instance FromJSON CancelReq where
  parseJSON = withObject "cancel" $ \o -> CancelReq <$> o .: "reason"

fromStartTournament :: StartT.StartTournamentError -> ApiError
fromStartTournament (StartT.Unauthorized a)     = fromAuthorization a
fromStartTournament (StartT.InvalidLifecycle l) = fromLifecycle l
fromStartTournament StartT.BracketNotGenerated  =
  ApiError status409 "BRACKET_REQUIRED"
    "Generate the bracket before starting the tournament" (object [])

fromTournamentError :: TournamentError -> ApiError
fromTournamentError TournamentNotComplete =
  ApiError status409 "TOURNAMENT_NOT_COMPLETE"
    "The tournament is not finished yet" (object [])
fromTournamentError TournamentAlreadyCompleted =
  ApiError status409 "TOURNAMENT_ALREADY_COMPLETED"
    "The tournament is already completed" (object [])
fromTournamentError TournamentAlreadyCancelled =
  ApiError status409 "TOURNAMENT_ALREADY_CANCELLED"
    "The tournament was cancelled" (object [])
fromTournamentError TournamentPaused =
  ApiError status409 "TOURNAMENT_PAUSED"
    "The tournament is paused" (object [])

fromComplete :: Complete.CompleteTournamentError -> ApiError
fromComplete (Complete.Unauthorized a)      = fromAuthorization a
fromComplete (Complete.InvalidCompletion e) = fromTournamentError e
fromComplete Complete.TournamentPausedCannotComplete =
  fromTournamentError TournamentPaused

fromCancel :: Cancel.CancelTournamentError -> ApiError
fromCancel (Cancel.Unauthorized a)     = fromAuthorization a
fromCancel (Cancel.InvalidLifecycle l) = fromLifecycle l
fromCancel Cancel.EmptyCancellationReason =
  ApiError status400 "VALIDATION_FAILED" "A cancellation reason is required"
    (object ["field" .= ("reason" :: Text)])

fromValidation :: TournamentValidationError -> ApiError
fromValidation EmptyName =
  ApiError status400 "VALIDATION_FAILED" "Tournament name must not be blank"
    (object ["field" .= ("name" :: Text)])
fromValidation EmptyOrganizer =
  ApiError status400 "VALIDATION_FAILED" "Organizer must not be blank"
    (object ["field" .= ("organizer" :: Text)])
fromValidation (MaxParticipantsTooLow n) =
  ApiError status400 "VALIDATION_FAILED" "maxParticipants is too low"
    (object ["field" .= ("maxParticipants" :: Text), "minimum" .= (2 :: Int), "actual" .= n])
fromValidation ThirdPlaceMatchRequiresSingleElimination =
  ApiError status400 "VALIDATION_FAILED"
    "Third-place match is only supported for Single Elimination"
    (object ["field" .= ("thirdPlaceMatch" :: Text)])

fromDetailsValidation :: DetailsValidationError -> ApiError
fromDetailsValidation (PrizeOutOfRange n) =
  ApiError status400 "VALIDATION_FAILED" "Prize must be a whole number of KSh, up to 1,000,000,000"
    (object ["field" .= ("prize" :: Text), "maximum" .= (1000000000 :: Int), "actual" .= n])
fromDetailsValidation DeadlineAfterStart =
  ApiError status400 "VALIDATION_FAILED" "Registration deadline must not be after the start time"
    (object ["field" .= ("registrationDeadline" :: Text)])
fromDetailsValidation (DescriptionTooLong n) =
  ApiError status400 "VALIDATION_FAILED" "Description must be 500 characters or fewer"
    (object ["field" .= ("description" :: Text), "maximum" .= (500 :: Int), "actual" .= n])
newtype FormatReq = FormatReq TournamentFormat

instance FromJSON FormatReq where
  parseJSON = withObject "format" $ \o -> do
    f <- o .: "format"
    case (f :: Text) of
      "SingleElimination" -> pure (FormatReq SingleElimination)
      "DoubleElimination" -> pure (FormatReq DoubleElimination)
      "RoundRobin"        -> pure (FormatReq RoundRobin)
      _ -> fail "format must be SingleElimination, DoubleElimination or RoundRobin"

fromUpdateFormat :: UTF.UpdateTournamentFormatError -> ApiError
fromUpdateFormat (UTF.Unauthorized a)      = fromAuthorization a
fromUpdateFormat (UTF.InvalidLifecycle l)  = fromLifecycle l
fromUpdateFormat (UTF.InvalidTournament v) = fromValidation v
fromUpdateFormat UTF.BracketAlreadyGenerated =
  ApiError status409 "BRACKET_ALREADY_GENERATED"
    "The format can't change once the bracket exists" (object [])

fromUpdateDetails :: UTD.UpdateTournamentDetailsError -> ApiError
fromUpdateDetails (UTD.Unauthorized a)     = fromAuthorization a
fromUpdateDetails (UTD.InvalidLifecycle l) = fromLifecycle l
fromUpdateDetails (UTD.InvalidDetails e)   = fromDetailsValidation e

data ParticipantReq
  = IndividualReq String
  | SquadReq String

instance FromJSON ParticipantReq where
  parseJSON = withObject "participant" $ \o -> do
    t <- o .: "type"
    case (t :: Text) of
      "Individual" -> IndividualReq <$> o .: "player"
      "Squad"      -> SquadReq <$> o .: "teamName"
      _            -> fail "type must be Individual or Squad"

fromRegister :: Register.RegisterParticipantCheckedError -> ApiError
fromRegister (Register.Unauthorized a)     = fromAuthorization a
fromRegister (Register.InvalidLifecycle l) = fromLifecycle l
fromRegister (Register.InvalidParticipant BlankPlayerName) =
  ApiError status400 "VALIDATION_FAILED" "Player name must not be blank"
    (object ["field" .= ("player" :: Text)])
fromRegister (Register.InvalidParticipant BlankTeamName) =
  ApiError status400 "VALIDATION_FAILED" "Team name must not be blank"
    (object ["field" .= ("team" :: Text)])
fromRegister Register.AlreadyRegistered =
  ApiError status409 "ALREADY_REGISTERED"
    "This participant is already registered" (object [])
fromRegister Register.CapacityReached =
  ApiError status409 "REGISTRATION_CAPACITY_REACHED"
    "The tournament is full" (object [])
fromRegister (Register.ParticipantKindNotAllowed mode) =
  ApiError status409 "PARTICIPANT_KIND_NOT_ALLOWED"
    "This tournament does not accept that kind of participant"
    (object ["allowed" .= T.pack (show mode)])

newtype ThirdPlaceMatchReq = ThirdPlaceMatchReq Bool

instance FromJSON ThirdPlaceMatchReq where
  parseJSON = withObject "thirdPlaceMatch" $ \o ->
    ThirdPlaceMatchReq <$> o .: "thirdPlaceMatch"

fromUpdateThirdPlaceMatch :: UTTP.UpdateTournamentThirdPlaceMatchError -> ApiError
fromUpdateThirdPlaceMatch (UTTP.Unauthorized a)     = fromAuthorization a
fromUpdateThirdPlaceMatch (UTTP.InvalidLifecycle l) = fromLifecycle l
fromUpdateThirdPlaceMatch (UTTP.InvalidTournament v) = fromValidation v
fromUpdateThirdPlaceMatch UTTP.BracketAlreadyGenerated =
  ApiError status409 "BRACKET_ALREADY_GENERATED"
    "The third-place setting can't change once the bracket exists" (object [])

newtype RequireApprovalReq = RequireApprovalReq Bool

instance FromJSON RequireApprovalReq where
  parseJSON = withObject "requireApproval" $ \o ->
    RequireApprovalReq <$> o .: "requireApproval"

fromUpdateRequireApproval :: UTRA.UpdateTournamentRequireApprovalError -> ApiError
fromUpdateRequireApproval (UTRA.Unauthorized a)     = fromAuthorization a
fromUpdateRequireApproval (UTRA.InvalidLifecycle l) = fromLifecycle l


data NameReq = NameReq String

instance FromJSON NameReq where
  parseJSON = withObject "name" $ \o -> NameReq <$> o .: "name"

data VisibilityReq = VisibilityReq Visibility

instance FromJSON VisibilityReq where
  parseJSON = withObject "visibility" $ \o -> do
    v <- o .: "visibility"
    case (v :: Text) of
      "Public"  -> pure (VisibilityReq Public)
      "Private" -> pure (VisibilityReq Private)
      _ -> fail "visibility must be Public or Private"

data MaxReq = MaxReq Int

instance FromJSON MaxReq where
  parseJSON = withObject "max" $ \o -> MaxReq <$> o .: "maxParticipants"

fromUpdateName :: UTN.UpdateTournamentNameError -> ApiError
fromUpdateName (UTN.Unauthorized a)      = fromAuthorization a
fromUpdateName (UTN.InvalidLifecycle l)  = fromLifecycle l
fromUpdateName (UTN.InvalidTournament v) = fromValidation v

fromUpdateVisibility :: UTV.UpdateTournamentVisibilityError -> ApiError
fromUpdateVisibility (UTV.Unauthorized a)     = fromAuthorization a
fromUpdateVisibility (UTV.InvalidLifecycle l) = fromLifecycle l

fromUpdateMax :: UTM.UpdateTournamentMaxParticipantsError -> ApiError
fromUpdateMax (UTM.Unauthorized a)      = fromAuthorization a
fromUpdateMax (UTM.InvalidLifecycle l)  = fromLifecycle l
fromUpdateMax (UTM.InvalidTournament v) = fromValidation v
fromUpdateMax UTM.BelowRegistrationCount =
  ApiError status409 "BELOW_REGISTRATION_COUNT"
    "More players or teams are already registered than that" (object [])

data ReopenReq = ReopenReq String

instance FromJSON ReopenReq where
  parseJSON = withObject "reopen" $ \o -> ReopenReq <$> o .: "reason"

fromPause :: PauseT.PauseTournamentError -> ApiError
fromPause (PauseT.Unauthorized a)     = fromAuthorization a
fromPause (PauseT.InvalidLifecycle l) = fromLifecycle l

fromResume :: ResumeT.ResumeTournamentError -> ApiError
fromResume (ResumeT.Unauthorized a)     = fromAuthorization a
fromResume (ResumeT.InvalidLifecycle l) = fromLifecycle l

fromReopen :: ReopenT.ReopenTournamentError -> ApiError
fromReopen (ReopenT.Unauthorized a)     = fromAuthorization a
fromReopen (ReopenT.InvalidLifecycle l) = fromLifecycle l
fromReopen ReopenT.EmptyReopeningReason =
  ApiError status400 "VALIDATION_FAILED" "A reason is required to reopen a tournament"
    (object ["field" .= ("reason" :: Text)])

data Env = Env
  { envLock   :: MVar ()
  , envTokens :: IORef (Map.Map Text (UserId, UTCTime))
  , envDbPath :: FilePath
  , envHashSem :: QSem          -- caps concurrent Argon2 runs (memory)
  , envDummyHash :: PasswordHash -- verified against for unknown usernames (timing)
  , envTokenTtl :: NominalDiffTime
  , envHits :: IORef (Map.Map (Text, Text) [UTCTime])  -- rate-limit hit log
  , envRateOn :: Bool
  , envTrustProxy :: Bool
  }

unauthenticated :: ApiError
unauthenticated = ApiError status401 "UNAUTHENTICATED"
  "Missing, invalid or expired credentials" (object [])

newToken :: IO Text
newToken = do
  bytes <- getEntropy 32
  pure (T.pack (concatMap hex2 (BS.unpack bytes)))
  where
    hex2 b = let h = showHex b "" in if length h < 2 then '0' : h else h

bearerToken :: ActionM (Maybe Text)
bearerToken = do
  raw <- header "Authorization"
  pure (TL.toStrict <$> (raw >>= TL.stripPrefix "Bearer "))

currentUser :: Env -> ActionM (Maybe UserId)
currentUser env = do
  mTok <- bearerToken
  case mTok of
    Nothing  -> pure Nothing
    Just tok -> do
      store0 <- liftIO (readIORef (envTokens env))
      now <- liftIO getCurrentTime
      let store = Map.mapMaybe (\(tUid, expAt) -> if expAt > now then Just tUid else Nothing) store0
      case Map.lookup tok store of
        Nothing  -> pure Nothing
        Just uid -> do
          r <- liftIO (tryAny (withMVar (envLock env)
                 (\_ -> runSQLiteM (envDbPath env) (Repo.findUserById uid))))
          pure $ case r of
            Right (Right (Just u)) | accountStatus u == Active -> Just uid
            _                                                   -> Nothing

resolveParticipantReq :: ParticipantReq -> SQLiteM Participant
resolveParticipantReq (IndividualReq n) =
  pure (Individual (Player (PlayerName n)))
resolveParticipantReq (SquadReq n) =
  Squad <$> Repo.getTeam (TeamName n)

data LoginReq = LoginReq Text Text

instance FromJSON LoginReq where
  parseJSON = withObject "login" $ \o -> do
    mi <- o .:? "identifier"
    u  <- maybe (o .: "username") pure mi
    LoginReq u <$> o .: "password"

fromLogin :: LU.LoginUserError -> ApiError
fromLogin LU.InvalidCredentials =
  ApiError status401 "INVALID_CREDENTIALS" "Wrong email, username or password" (object [])
fromLogin (LU.AccountNotActive s) =
  ApiError status403 "ACCOUNT_NOT_ACTIVE" "This account cannot log in"
    (object ["status" .= show s])

data RegisterReq = RegisterReq Text Text Text (Maybe Text)

instance FromJSON RegisterReq where
  parseJSON = withObject "register" $ \o ->
    RegisterReq <$> o .: "username" <*> o .: "email" <*> o .: "password" <*> o .:? "fullName"

newtype ForgotReq = ForgotReq Text

instance FromJSON ForgotReq where
  parseJSON = withObject "forgot" $ \o -> ForgotReq <$> o .: "email"

data ResetReq = ResetReq Text Text

instance FromJSON ResetReq where
  parseJSON = withObject "reset" $ \o -> ResetReq <$> o .: "token" <*> o .: "password"

badResetLink :: ApiError
badResetLink =
  ApiError status400 "INVALID_RESET_LINK" "This reset link is invalid or has expired" (object [])

-- Always does the same work, whether or not the account exists, so timing
-- does not reveal which emails have accounts. Email sending comes later:
-- for now the link is printed in the API console.
issueReset :: Env -> Text -> ActionM ()
issueReset lock e = do
  tok <- liftIO newToken
  hr <- liftIO (tryAny (withHashSlot lock (hashPasswordIO tok)))
  mu <- runUseCase lock (Repo.findUserByEmail (Email e))
  nowT <- liftIO getCurrentTime
  let nowS = floor (utcTimeToPOSIXSeconds nowT) :: Int
  case (hr, mu) of
    (Right h, Right (Just u)) | accountStatus u == Active -> do
      let PasswordHash hashText = h
      r <- runUseCase lock (Repo.createPasswordReset (userId u) hashText (nowS + 1800))
      case r of
        Right rid -> liftIO (hPutStrLn stderr
          ("[password reset] http://localhost:5173/reset-password?token=" ++ show rid ++ "." ++ T.unpack tok))
        Left _ -> pure ()
    _ -> pure ()

applyReset :: Int -> UserId -> PasswordHash -> SQLiteM Bool
applyReset rid uid newHash = do
  mr <- Repo.findPasswordReset rid
  case mr of
    Just (_, _, _, False) -> do
      Repo.updatePasswordHash uid newHash
      Repo.consumePasswordResets uid
      pure True
    _ -> pure False

redeemReset :: Env -> Text -> Text -> ActionM Bool
redeemReset lock token pw = do
  let (ridT, rest) = T.breakOn "." token
      secret = T.drop 1 rest
  case readMaybe (T.unpack ridT) :: Maybe Int of
    Nothing -> pure False
    Just rid -> do
      mr <- runUseCase lock (Repo.findPasswordReset rid)
      nowT <- liftIO getCurrentTime
      let nowS = floor (utcTimeToPOSIXSeconds nowT) :: Int
          stored = case mr of
            Right (Just (uid, h, e, False)) | e > nowS -> Just (uid, h)
            _ -> Nothing
          hashToCheck = maybe (envDummyHash lock) (PasswordHash . snd) stored
      v <- liftIO (tryAny (withHashSlot lock (evaluate (verifyPasswordPure secret hashToCheck))))
      case (v, stored) of
        (Right True, Just (uid, _)) -> do
          hr <- liftIO (tryAny (withHashSlot lock (hashPasswordIO pw)))
          case hr of
            Right newHash -> do
              r <- runUseCase lock (applyReset rid uid newHash)
              case r of
                Right True -> do
                  -- sign the user out everywhere
                  liftIO (atomicModifyIORef' (envTokens lock)
                            (\m -> (Map.filter ((/= uid) . fst) m, ())))
                  pure True
                _ -> pure False
            Left _ -> pure False
        _ -> pure False

nameTooLong :: ApiError
nameTooLong =
  ApiError status400 "VALIDATION_FAILED" "Full name must be 60 characters or fewer"
    (object ["field" .= ("fullName" :: Text)])

fromRegisterUser :: RU.RegisterUserError -> ApiError
fromRegisterUser (RU.InvalidUser err) = case err of
  InvalidUsername _ ->
    ApiError status400 "VALIDATION_FAILED"
      "Username must be 3 to 30 characters: letters, digits or underscore"
      (object [ "field" .= ("username" :: Text)
              , "minLength" .= (3 :: Int), "maxLength" .= (30 :: Int) ])
  InvalidEmail _ ->
    ApiError status400 "VALIDATION_FAILED" "Email address is not valid"
      (object ["field" .= ("email" :: Text)])
  EmptyPassword ->
    ApiError status400 "VALIDATION_FAILED" "Password must not be empty"
      (object ["field" .= ("password" :: Text)])
  PasswordTooShort ->
    ApiError status400 "VALIDATION_FAILED" "Password must be at least 8 characters"
      (object ["field" .= ("password" :: Text), "minLength" .= (8 :: Int)])
  EmptyPasswordHash -> internalError
fromRegisterUser RU.UsernameTaken =
  ApiError status409 "USERNAME_TAKEN" "That username is already taken" (object [])
fromRegisterUser RU.EmailTaken =
  ApiError status409 "EMAIL_TAKEN" "That email is already registered" (object [])







-- ===== Helpers =====

-- ===== Rate limiting (in memory) =====

data RateRule = RateRule
  { ruleBucket  :: Text
  , ruleWindow  :: NominalDiffTime
  , ruleMax     :: Int
  , ruleLockFor :: Maybe NominalDiffTime
  }

loginUserRule, loginIpRule, registerIpRule :: RateRule
loginUserRule  = RateRule "login-user"  900  5 (Just 300)
loginIpRule    = RateRule "login-ip"    600 30 Nothing
registerIpRule = RateRule "register-ip" 3600 10 Nothing

forgotIpRule, resetIpRule :: RateRule
forgotIpRule = RateRule "forgot-ip" 3600 5 Nothing
resetIpRule  = RateRule "reset-ip"  3600 20 Nothing

pruneHits :: UTCTime -> NominalDiffTime -> [UTCTime] -> [UTCTime]
pruneHits now w = filter (\t -> diffUTCTime now t < w)

-- | Seconds until another attempt is allowed; Nothing = allowed now.
blockedFor :: Env -> RateRule -> Text -> IO (Maybe Int)
blockedFor env rule key
  | not (envRateOn env) = pure Nothing
  | otherwise = do
      now <- getCurrentTime
      m   <- readIORef (envHits env)
      let ts = maybe [] (pruneHits now (ruleWindow rule)) (Map.lookup (ruleBucket rule, key) m)
      pure $
        if length ts < ruleMax rule then Nothing
        else
          let waitS = case ruleLockFor rule of
                Just lockFor -> lockFor - diffUTCTime now (maximum ts)
                Nothing      -> ruleWindow rule - diffUTCTime now (minimum ts)
          in if waitS > 0 then Just (ceiling waitS) else Nothing

recordHit :: Env -> RateRule -> Text -> IO ()
recordHit env rule key = when (envRateOn env) $ do
  now <- getCurrentTime
  atomicModifyIORef' (envHits env) $ \m ->
    let pruned = Map.filter (not . null) (Map.map (pruneHits now 3600) m)
    in (Map.insertWith (++) (ruleBucket rule, key) [now] pruned, ())

clearHits :: Env -> RateRule -> Text -> IO ()
clearHits env rule key =
  atomicModifyIORef' (envHits env) (\m -> (Map.delete (ruleBucket rule, key) m, ()))

firstBlocked :: [IO (Maybe Int)] -> IO (Maybe Int)
firstBlocked []     = pure Nothing
firstBlocked (a:as) = a >>= maybe (firstBlocked as) (pure . Just)

tooMany :: Int -> ApiError
tooMany secs = ApiError status429 "TOO_MANY_ATTEMPTS"
  "Too many attempts, try again later" (object ["retryAfterSeconds" .= secs])

peerIp :: String -> Text
peerIp s = case s of
  ('[':rest) -> T.pack (takeWhile (/= ']') rest)
  _          -> T.pack (reverse (drop 1 (dropWhile (/= ':') (reverse s))))

-- | Real client IP. X-Forwarded-For (rightmost entry, set by our own proxy)
-- is honoured only when ARENAOS_TRUST_PROXY=1.
clientIp :: Env -> ActionM Text
clientIp env = do
  req <- request
  let direct = peerIp (show (remoteHost req))
      fwd    = lookup "x-forwarded-for" (requestHeaders req)
      latin1 = T.pack . map (toEnum . fromIntegral) . BS.unpack
  pure $ case fwd of
    Just v | envTrustProxy env ->
      let parts = map T.strip (T.splitOn "," (latin1 v))
      in if null parts || T.null (last parts) then direct else last parts
    _ -> direct

withHashSlot :: Env -> IO a -> IO a
withHashSlot env = bracket_ (waitQSem (envHashSem env)) (signalQSem (envHashSem env))

tryAny :: IO a -> IO (Either SomeException a)
tryAny = try

runUseCase :: Env -> SQLiteM a -> ActionM (Either ApiError a)
runUseCase lock action = do
  outcome <- liftIO (tryAny (withMVar (envLock lock) (\_ -> runSQLiteM (envDbPath lock) action)))
  case outcome of
    Left ex -> do
      liftIO (hPutStrLn stderr ("unhandled: " ++ show ex))
      pure (Left internalError)
    Right (Left perr) -> do
      liftIO (hPutStrLn stderr (show perr))
      pure (Left (fromPersistence perr))
    Right (Right a) -> pure (Right a)

runAction
  :: Env
  -> (UserId -> TournamentId -> SQLiteM (Either e a))
  -> (e -> ApiError)
  -> (a -> ActionM ())
  -> ActionM ()
runAction lock useCase toApiError onSuccess = do
  rawId <- pathParam "id"
  mUser <- currentUser lock
  case (readMaybe (T.unpack rawId), mUser) of
    (_, Nothing)         -> sendError unauthenticated
    (Nothing, _)         -> sendError (ApiError status400 "BAD_REQUEST" "Invalid id" (object []))
    (Just tid, Just uid) -> do
      result <- runUseCase lock (useCase uid (TournamentId tid))
      case result of
        Left apiErr     -> sendError apiErr
        Right (Left e)  -> sendError (toApiError e)
        Right (Right a) -> onSuccess a

runMatchAction
  :: Env
  -> (UserId -> MatchId -> SQLiteM (Either e a))
  -> (e -> ApiError)
  -> (a -> ActionM ())
  -> ActionM ()
runMatchAction lock useCase toApiError onSuccess = do
  rawId <- pathParam "id"
  mUser <- currentUser lock
  case (readMaybe (T.unpack rawId), mUser) of
    (_, Nothing)         -> sendError unauthenticated
    (Nothing, _)         -> sendError (ApiError status400 "BAD_REQUEST" "Invalid id" (object []))
    (Just mid, Just uid) -> do
      result <- runUseCase lock (useCase uid (MatchId mid))
      case result of
        Left apiErr     -> sendError apiErr
        Right (Left e)  -> sendError (toApiError e)
        Right (Right a) -> onSuccess a
        
runTransition
  :: Env
  -> (UserId -> TournamentId -> SQLiteM (Either e ()))
  -> (e -> ApiError)
  -> ActionM ()
runTransition lock useCase toApiError =
  runAction lock useCase toApiError (\() -> status status204)


-- Anonymous is fine; a credential that is present but invalid is not.
viewer :: Env -> ActionM (Either ApiError (Maybe UserId))
viewer env = do
  raw <- header "Authorization"
  case raw of
    Nothing -> pure (Right Nothing)
    Just _  -> do
      mUid <- currentUser env
      pure (maybe (Left unauthenticated) (Right . Just) mUid)

runViewAction
  :: Env
  -> (Maybe UserId -> TournamentId -> SQLiteM (Either e a))
  -> (e -> ApiError)
  -> (a -> ActionM ())
  -> ActionM ()
runViewAction lock useCase toApiError onSuccess = do
  rawId <- pathParam "id"
  mv    <- viewer lock
  case (readMaybe (T.unpack rawId), mv) of
    (_, Left err)        -> sendError err
    (Nothing, _)         -> sendError (ApiError status400 "BAD_REQUEST" "Invalid id" (object []))
    (Just tid, Right mu) -> do
      result <- runUseCase lock (useCase mu (TournamentId tid))
      case result of
        Left apiErr     -> sendError apiErr
        Right (Left e)  -> sendError (toApiError e)
        Right (Right a) -> onSuccess a



-- ===== Routes =====

main :: IO ()
main = do
  dbFile <- envOr "ARENAOS_DB" defaultDbPath
  host   <- envOr "ARENAOS_HOST" "127.0.0.1"
  port   <- readPort
  ttlSecs    <- readIntEnv "ARENAOS_TOKEN_TTL_SECONDS" 604800
  rateOn     <- (/= "off") <$> envOr "ARENAOS_RATE_LIMIT" "on"
  trustProxy <- (== "1") <$> envOr "ARENAOS_TRUST_PROXY" "0"
  initResult <- runSQLiteM dbFile $ do
    env <- ask
    liftIO (initializeSchema (envConnection env))
  case initResult of
    Left err -> hPutStrLn stderr ("schema init failed: " ++ show err) >> exitFailure
    Right () -> pure ()
  dummyHash <- newToken >>= hashPasswordIO
  lock <- Env <$> newMVar () <*> newIORef Map.empty <*> pure dbFile
                <*> newQSem 2 <*> pure dummyHash
                <*> pure (fromIntegral ttlSecs) <*> newIORef Map.empty
                <*> pure rateOn <*> pure trustProxy
  let opts = Options
        { verbose  = 1
        , settings = setHost (fromString host) (setPort port defaultSettings)
        , jsonMode = False }
  scottyOpts opts $ do
    get "/health" $ json (object ["status" .= ("ok" :: Text)])

    post "/tournaments/:id/publish" $
      runTransition lock Publish.publishTournament $ \e -> case e of
        Publish.Unauthorized a     -> fromAuthorization a
        Publish.InvalidLifecycle l -> fromLifecycle l 

    post "/tournaments/:id/open-registration" $
      runTransition lock Open.openRegistration $ \e -> case e of
        Open.Unauthorized a     -> fromAuthorization a
        Open.InvalidLifecycle l -> fromLifecycle l

    post "/tournaments/:id/close-registration" $
      runTransition lock Close.closeRegistration $ \e -> case e of
        Close.Unauthorized a     -> fromAuthorization a
        Close.InvalidLifecycle l -> fromLifecycle l

    post "/tournaments/:id/bracket" $
      runAction lock Generate.generateBracket fromGenerate $ \bid -> do
        status status201
        json (object ["bracketId" .= unBracketId bid])

    put "/matches/:id/schedule" $ do
      raw <- body
      case eitherDecode raw of
        Left reason -> sendError (invalidBody reason)
        Right (ScheduleReq start) ->
          runMatchAction lock (\uid mid -> Sched.setMatchSchedule uid mid start) fromSetSchedule $ \m ->
            json (matchJson m)

    post "/matches/:id/start" $
      runMatchAction lock Start.startMatch fromStart $ \m ->
        json (matchJson m)

    post "/matches/:id/result" $ do
      raw <- body
      case eitherDecode raw of
        Left reason -> sendError (invalidBody reason)
        Right req   ->
          runMatchAction lock (\uid mid -> recordViaApi uid mid req) fromRecord $ \m ->
            json (matchJson m)

    put "/matches/:id/result" $ do
      raw <- body
      case eitherDecode raw of
        Left reason -> sendError (invalidBody reason)
        Right req   ->
          runMatchAction lock (\uid mid -> correctViaApi uid mid req) fromCorrect $ \m ->
            json (matchJson m)

    put "/matches/:id/efootball-result" $ do
      raw <- body
      case eitherDecode raw of
        Left reason -> sendError (invalidBody reason)
        Right (EFootballResultReq scoreA scoreB) ->
          runMatchAction lock
            (\uid mid -> correctEFootballResult uid mid scoreA scoreB)
            fromCorrectEFootball
            $ \m -> json (matchJson m)

    post "/matches/:id/efootball-result" $ do
      raw <- body
      case eitherDecode raw of
        Left reason -> sendError (invalidBody reason)
        Right (EFootballResultReq scoreA scoreB) ->
          runMatchAction lock
            (\uid mid -> recordEFootballResult uid mid scoreA scoreB)
            fromRecordEFootball
            $ \m -> json (matchJson m)

    
    post "/tournaments" $ do
      mUser <- currentUser lock
      raw   <- body
      case (mUser, eitherDecode raw) of
        (Nothing, _) -> sendError unauthenticated
                    --      "Missing or invalid X-User-Id header" (object []))
        (_, Left reason) -> sendError (invalidBody reason)
        (Just uid, Right req) -> do
          result <- runUseCase lock
                      (Create.createTournamentWithApproval (toNewTournament uid req) (reqDetails req) (reqRequireApproval req))
                 --     (Create.createTournamentChecked (toNewTournament (UserId uid) req))
          case result of
            Left apiErr -> sendError apiErr
            Right (Left (Create.CreateInvalid v)) -> sendError (fromValidation v)
            Right (Left (Create.CreateInvalidDetails e)) -> sendError (fromDetailsValidation e)
            Right (Right tid) -> do
              status status201
              json (object ["tournamentId" .= unTournamentId tid])
              
    post "/tournaments/:id/registrations" $ do
      raw <- body
      case eitherDecode raw of
        Left reason -> sendError (invalidBody reason)
        Right req -> do
          resolved <- do
            mu <- currentUser lock
            case mu of
              Nothing -> pure (Left unauthenticated)
              Just _  -> runUseCase lock (resolveParticipantReq req)
          case resolved of
            Left apiErr -> sendError apiErr
            Right p ->
              runAction lock
                (\uid tid -> Register.registerParticipantChecked uid tid p)
                fromRegister $ \rid -> do
                  status status201
                  json (object ["registrationId" .= unRegistrationId rid])

    post "/tournaments/:id/join" $ do
      nowT <- liftIO getCurrentTime
      runAction lock (JRQ.joinOrRequestAt nowT) fromJoinOrRequest $ \outcome -> do
        status status201
        case outcome of
          JRQ.Joined rid ->
            json (object ["status" .= ("Joined" :: Text), "registrationId" .= unRegistrationId rid])
          JRQ.RequestPending ->
            json (object ["status" .= ("Pending" :: Text)])

    post "/tournaments/:id/cancel-request" $
      runAction lock JRQ.cancelJoinRequest fromCancelRequest (\() -> status status204)

    get "/tournaments/:id/requests" $
      runAction lock JRQ.listJoinRequestsForOwner fromListRequests $ \es ->
        json (object ["requests" .= map entryJson es])

    post "/tournaments/:id/requests/approve" $ do
      raw <- body
      case eitherDecode raw of
        Left reason -> sendError (invalidBody reason)
        Right (TargetUserReq target) ->
          runAction lock
            (\uid tid -> JRQ.approveJoinRequest uid tid (UserId target))
            fromApprove $ \rid -> do
              status status201
              json (object ["registrationId" .= unRegistrationId rid])

    post "/tournaments/:id/requests/decline" $ do
      raw <- body
      case eitherDecode raw of
        Left reason -> sendError (invalidBody reason)
        Right (TargetUserReq target) ->
          runTransition lock
            (\uid tid -> JRQ.declineJoinRequest uid tid (UserId target))
            fromDecline

    post "/tournaments/:id/registrations/remove" $ do
      raw <- body
      case eitherDecode raw of
        Left reason -> sendError (invalidBody reason)
        Right req -> do
          resolved <- do
            mu <- currentUser lock
            case mu of
              Nothing -> pure (Left unauthenticated)
              Just _  -> runUseCase lock (resolveParticipantReq req)
          case resolved of
            Left apiErr -> sendError apiErr
            Right p ->
              runAction lock
                (\uid tid -> Register.removeParticipant uid tid p)
                fromRemove (\() -> status status204)

    post "/tournaments/:id/withdraw" $
      runAction lock Register.withdrawFromTournament fromWithdraw (\() -> status status204)

    get "/me/registrations" $ do
      mUser <- currentUser lock
      case mUser of
        Nothing  -> sendError unauthenticated
        Just uid -> do
          result <- runUseCase lock ((,) <$> Register.listMyRegistrations uid <*> Repo.countRegistrationsByTournament)
          case result of
            Left apiErr -> sendError apiErr
            Right (ts, counts) -> json (object
              [ "tournaments" .=
                  map (\t -> tournamentJsonCounted (countFor counts t) t) (sortOn (negate . unTournamentId . tournamentId) ts) ])

    post "/tournaments/:id/join-team" $ do
      raw <- body
      case eitherDecode raw of
        Left reason -> sendError (invalidBody reason)
        Right (JoinTeamReq n) -> do
          nowT <- liftIO getCurrentTime
          runAction lock (\uid tid -> Register.joinTournamentAsTeam nowT uid tid n) fromJoinTeam $ \rid -> do
            status status201
            json (object ["registrationId" .= unRegistrationId rid])

    get "/me/teams" $ do
      mUser <- currentUser lock
      case mUser of
        Nothing  -> sendError unauthenticated
        Just uid -> do
          result <- runUseCase lock (Repo.listTeamsByOwner uid)
          case result of
            Left apiErr -> sendError apiErr
            Right ts    -> json (object ["teams" .= map teamJson ts])

    get "/me/match-summary" $ do
      mUser <- currentUser lock
      case mUser of
        Nothing  -> sendError unauthenticated
        Just uid -> do
          result <- runUseCase lock (ListMine.myMatchSummary uid)
          case result of
            Left apiErr -> sendError apiErr
            Right s -> json (object
              [ "nextMatch" .= fmap (\(t, m) -> object
                  [ "tournamentId"   .= unTournamentId (tournamentId t)
                  , "tournamentName" .= unTournamentName (tournamentName t)
                  , "match"          .= matchJson m ]) (ListMine.msNext s)
              , "tournamentsWon" .= ListMine.msWon s ])

    post "/login" $ do
      raw <- body
      case eitherDecode raw of
        Left reason -> sendError (invalidBody reason)
        Right (LoginReq u p) -> do
          ip <- clientIp lock
          let ukey = T.take 64 (T.toLower u)
              loginReq = LU.LoginUserRequest (Username u) p
          blocked <- liftIO (firstBlocked
                       [blockedFor lock loginIpRule ip, blockedFor lock loginUserRule ukey])
          result <- case blocked of
            Just secs -> do
              setHeader "Retry-After" (TL.pack (show secs))
              pure (Left (tooMany secs))
            Nothing -> do
              looked <- runUseCase lock (LU.lookupForLogin loginReq)
              case looked of
                Left apiErr -> pure (Left apiErr)
                Right mUser -> do
                  let h = maybe (envDummyHash lock) passwordHash mUser
                  ok <- liftIO (tryAny (withHashSlot lock (evaluate (verifyPasswordPure p h))))
                  pure $ case ok of
                    Left _  -> Left internalError
                    Right v -> Right (LU.finishLogin mUser (v && isJust mUser))
          liftIO $ case result of
            Right (Left LU.InvalidCredentials) ->
              recordHit lock loginIpRule ip >> recordHit lock loginUserRule ukey
            Right (Right _) -> clearHits lock loginUserRule ukey
            _               -> pure ()
          case result of
            Left apiErr    -> sendError apiErr
            Right (Left e) -> sendError (fromLogin e)
            Right (Right user) -> do
              tok <- liftIO newToken
              nowT <- liftIO getCurrentTime
              let expiresAt = addUTCTime (envTokenTtl lock) nowT
              liftIO (atomicModifyIORef' (envTokens lock)
                        (\m -> (Map.insert tok (userId user, expiresAt) (Map.filter ((> nowT) . snd) m), ())))
              let Username uname = username user
              fullResult <- runUseCase lock (Repo.getFullName (userId user))
              let fullName = either (const Nothing) id fullResult

              json (object [ "token" .= tok
                           , "user"  .= object [ "id"       .= unUserId (userId user)
                                               , "username" .= uname
                                               , "fullName" .= fullName ] ])

    post "/forgot-password" $ do
      raw <- body
      case eitherDecode raw of
        Left reason -> sendError (invalidBody reason)
        Right (ForgotReq e) -> do
          ip <- clientIp lock
          blocked <- liftIO (blockedFor lock forgotIpRule ip)
          case blocked of
            Just secs -> do
              setHeader "Retry-After" (TL.pack (show secs))
              sendError (tooMany secs)
            Nothing -> do
              liftIO (recordHit lock forgotIpRule ip)
              issueReset lock (T.strip e)
              json (object ["ok" .= True])

    post "/reset-password" $ do
      raw <- body
      case eitherDecode raw of
        Left reason -> sendError (invalidBody reason)
        Right (ResetReq tok pw) -> do
          ip <- clientIp lock
          blocked <- liftIO (blockedFor lock resetIpRule ip)
          case blocked of
            Just secs -> do
              setHeader "Retry-After" (TL.pack (show secs))
              sendError (tooMany secs)
            Nothing -> do
              liftIO (recordHit lock resetIpRule ip)
              case EU.validateRawPassword pw of
                Left _ -> sendError (ApiError status400 "VALIDATION_FAILED"
                            "Password must be at least 8 characters"
                            (object ["field" .= ("password" :: Text), "minLength" .= (8 :: Int)]))
                Right _ -> do
                  ok <- redeemReset lock tok pw
                  if ok then status status204 else sendError badResetLink

    post "/logout" $ do
      mTok <- bearerToken
      case mTok of
        Nothing  -> sendError unauthenticated
        Just tok -> do
          liftIO (atomicModifyIORef' (envTokens lock) (\m -> (Map.delete tok m, ())))
          status status204

    post "/register" $ do
      raw <- body
      case eitherDecode raw of
        Left reason -> sendError (invalidBody reason)
        Right (RegisterReq u e p mFull) -> do
          ip <- clientIp lock
          blocked <- liftIO (blockedFor lock registerIpRule ip)
          let regReq = RU.RegisterUserRequest (Username u) (Email e) p
              nameCheck = maybe (Right Nothing) EU.validateFullName mFull
          result <- case blocked of
            Just secs -> do
              setHeader "Retry-After" (TL.pack (show secs))
              pure (Left (tooMany secs))
            Nothing -> case (nameCheck, RU.validateRegistration regReq) of
              (Left _, _) -> pure (Left nameTooLong)
              (_, Left verr) -> pure (Right (Left verr))
              (Right _, Right ()) -> do
                liftIO (recordHit lock registerIpRule ip)
                hr <- liftIO (tryAny (withHashSlot lock (hashPasswordIO p)))
                case hr of
                  Left ex -> do
                    liftIO (hPutStrLn stderr ("hash failed: " ++ show ex))
                    pure (Left internalError)
                  Right h -> runUseCase lock (RU.registerWithHash regReq h)
          case result of
            Left apiErr      -> sendError apiErr
            Right (Left err) -> sendError (fromRegisterUser err)
            Right (Right user) -> do
              status status201
              let Username uname = username user
              let fullToSave = either (const Nothing) id nameCheck
              _ <- runUseCase lock (Repo.setFullName (userId user) fullToSave)

              json (object [ "id" .= unUserId (userId user)
                           , "username" .= uname ])
    
    get "/me/tournaments" $ do
      mUser <- currentUser lock
      case mUser of
        Nothing  -> sendError unauthenticated
        Just uid -> do
          result <- runUseCase lock ((,) <$> ListMine.listMyTournaments uid <*> Repo.countRegistrationsByTournament)
          case result of
            Left apiErr -> sendError apiErr
            Right ts    -> json (object
              [ "tournaments" .=
                  map (\t -> tournamentJsonCounted (countFor (snd ts) t) t) (sortOn (negate . unTournamentId . tournamentId) (fst ts)) ])
    
    post "/tournaments/:id/start" $
      runTransition lock StartT.startTournament fromStartTournament

    post "/tournaments/:id/complete" $
      runAction lock Complete.completeTournament fromComplete $ \t ->
        json (tournamentJson t)

    post "/tournaments/:id/cancel" $ do
      raw <- body
      case eitherDecode raw of
        Left reason -> sendError (invalidBody reason)
        Right (CancelReq why) ->
          runTransition lock
            (\uid tid -> Cancel.cancelTournament uid tid why) fromCancel

    get "/tournaments/:id/bracket" $
      runViewAction lock getBracketWithScores fromGetBracket $ \(v, scores) ->
        json (bracketViewJson scores v)

    get "/tournaments/:id" $
      runViewAction lock GetT.getTournament fromGetTournament $ \v ->
        json (tournamentViewJson v)

    -- public, no login: counts over public tournaments past Draft
    get "/stats" $ do
      result <- runUseCase lock Repo.publicStats
      case result of
        Left apiErr -> sendError apiErr
        Right s     -> json (statsJson s)

    get "/me/notifications" $ do
      mUser <- currentUser lock
      case mUser of
        Nothing  -> sendError unauthenticated
        Just uid -> do
          result <- runUseCase lock ((,) <$> Repo.listNotifications uid 20 <*> Repo.countUnreadNotifications uid)
          case result of
            Left apiErr -> sendError apiErr
            Right (ns, unread) -> json (object ["unread" .= unread, "notifications" .= map notificationJson ns])

    post "/me/notifications/read" $ do
      mUser <- currentUser lock
      case mUser of
        Nothing  -> sendError unauthenticated
        Just uid -> do
          result <- runUseCase lock (Repo.markAllNotificationsRead uid)
          case result of
            Left apiErr -> sendError apiErr
            Right ()    -> status status204

    -- public, no login: player directory and profiles (public tournaments only)
    get "/players" $ do
      qRaw <- (queryParamMaybe "q" :: ActionM (Maybe Text))
      lRaw <- (queryParamMaybe "limit" :: ActionM (Maybe Text))
      case parsePlayersQuery qRaw lRaw of
        Left apiErr -> sendError apiErr
        Right (mq, limitN) -> do
          result <- runUseCase lock (GPL.getPlayers mq limitN)
          case result of
            Left apiErr -> sendError apiErr
            Right ss    -> json (object ["players" .= map playerSummaryJson ss])

    get "/players/:name" $ do
      rawName <- pathParam "name" :: ActionM Text
      result <- runUseCase lock (GPL.getPlayerProfile (T.unpack rawName))
      case result of
        Left apiErr    -> sendError apiErr
        Right Nothing  -> sendError (ApiError status404 "NOT_FOUND" "Player not found" (object []))
        Right (Just p) -> json (playerProfileJson p)

    -- public, no login: top players by titles, then match wins
    get "/rankings" $ do
      gRaw <- (queryParamMaybe "game" :: ActionM (Maybe Text))
      lRaw <- (queryParamMaybe "limit" :: ActionM (Maybe Text))
      case parseRankingsQuery gRaw lRaw of
        Left apiErr -> sendError apiErr
        Right (mGame, limitN) -> do
          result <- runUseCase lock (GRK.getRankings mGame limitN)
          case result of
            Left apiErr -> sendError apiErr
            Right es    -> json (object ["rankings" .= map rankingJson (Rk.assignRanks es)])

    -- public, no login: latest events of public tournaments past Draft
    get "/activity" $ do
      result <- runUseCase lock (Repo.recentPublicActivity 10)
      case result of
        Left apiErr -> sendError apiErr
        Right items -> json (object ["activity" .= map activityJson items])

    get "/tournaments" $ do
      mv <- viewer lock
      case mv of
        Left err -> sendError err
        Right _  -> do
          qRaw <- (queryParamMaybe "q" :: ActionM (Maybe Text))
          gRaw <- (queryParamMaybe "game" :: ActionM (Maybe Text))
          lRaw <- (queryParamMaybe "limit" :: ActionM (Maybe Text))
          uRaw <- (queryParamMaybe "upcoming" :: ActionM (Maybe Text))
          nowT <- liftIO getCurrentTime
          result <- case parseListFilter nowT qRaw gRaw lRaw uRaw of
            Left apiErr -> pure (Left apiErr)
            Right flt   -> runUseCase lock ((,) <$> ListPublic.listPublicTournamentsFiltered flt <*> Repo.countRegistrationsByTournament)
          case result of
            Left apiErr -> sendError apiErr
            Right ts    -> json (object ["tournaments" .= map (\t -> tournamentJsonCounted (countFor (snd ts) t) t) (fst ts)])

    put "/tournaments/:id/name" $ do
      raw <- body
      case eitherDecode raw of
        Left reason -> sendError (invalidBody reason)
        Right (NameReq n) ->
          runTransition lock
            (\uid tid -> UTN.updateTournamentName uid tid (TournamentName n)) fromUpdateName

    put "/tournaments/:id/visibility" $ do
      raw <- body
      case eitherDecode raw of
        Left reason -> sendError (invalidBody reason)
        Right (VisibilityReq v) ->
          runTransition lock
            (\uid tid -> UTV.updateTournamentVisibility uid tid v) fromUpdateVisibility

    put "/tournaments/:id/max-participants" $ do
      raw <- body
      case eitherDecode raw of
        Left reason -> sendError (invalidBody reason)
        Right (MaxReq n) ->
          runTransition lock
            (\uid tid -> UTM.updateTournamentMaxParticipants uid tid n) fromUpdateMax

    put "/tournaments/:id/format" $ do
      raw <- body
      case eitherDecode raw of
        Left reason -> sendError (invalidBody reason)
        Right (FormatReq f) ->
          runTransition lock
            (\uid tid -> UTF.updateTournamentFormat uid tid f) fromUpdateFormat

    put "/tournaments/:id/details" $ do
      raw <- body
      case eitherDecode raw of
        Left reason -> sendError (invalidBody reason)
        Right (DetailsReq d) ->
          runTransition lock
            (\uid tid -> UTD.updateTournamentDetails uid tid d) fromUpdateDetails

    post "/tournaments/:id/pause" $
      runTransition lock PauseT.pauseTournament fromPause

    post "/tournaments/:id/resume" $
      runTransition lock ResumeT.resumeTournament fromResume

    post "/tournaments/:id/reopen" $ do
      raw <- body
      case eitherDecode raw of
        Left reason -> sendError (invalidBody reason)
        Right (ReopenReq r) ->
          runTransition lock
            (\uid tid -> ReopenT.reopenTournament uid tid r) fromReopen

    post "/tournaments/:id/third-place-match" $ do
      raw <- body
      case eitherDecode raw of
        Left reason -> sendError (invalidBody reason)
        Right (ThirdPlaceMatchReq tp) ->
          runTransition lock
            (\uid tid -> UTTP.updateTournamentThirdPlaceMatch uid tid tp) fromUpdateThirdPlaceMatch

    post "/tournaments/:id/require-approval" $ do
      raw <- body
      case eitherDecode raw of
        Left reason -> sendError (invalidBody reason)
        Right (RequireApprovalReq ra) ->
          runTransition lock
            (\uid tid -> UTRA.updateTournamentRequireApproval uid tid ra) fromUpdateRequireApproval

    get "/teams" $ do
      mUser <- currentUser lock
      case mUser of
        Nothing -> sendError unauthenticated
        Just _  -> do
          result <- runUseCase lock Repo.listTeams
          case result of
            Left apiErr -> sendError apiErr
            Right ts    -> json (object ["teams" .= map teamJson ts])

    post "/teams" $ do
      mUser <- currentUser lock
      raw   <- body
      case (mUser, eitherDecode raw) of
        (Nothing, _) -> sendError unauthenticated
        (_, Left reason) -> sendError (invalidBody reason)
        (Just uid, Right req) -> do
          let team = toTeam req
          result <- runUseCase lock (createTeam team)
          case result of
            Left apiErr -> sendError apiErr
            Right (Left teamErr) -> sendError (fromCreateTeam teamErr)
            Right (Right ()) -> do
              status status201
              _ <- runUseCase lock (Repo.setTeamOwner (teamName team) uid)

              json (teamJson team)

              

    notFound $ sendError
      (ApiError status404 "ROUTE_NOT_FOUND" "No such endpoint" (object []))
