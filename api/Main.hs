{-# LANGUAGE OverloadedStrings #-}
module Main where

import Web.Scotty
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Text.Read (readMaybe)
import Control.Monad.IO.Class (liftIO)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (SomeException, try)
import System.IO (hPutStrLn, stderr)
import Network.HTTP.Types
  (Status, status201, status204, status400, status401, status403, status404, status409, status500)
import Data.Aeson
  (Value, object, (.=), FromJSON(..), withObject, withText, (.:), (.:?), (.!=), eitherDecode)

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
import Domain.Scoreable (EFootballScore, mkEFootballScore, ScoreError(..))
import Application.UseCases.RecordEFootballResult (recordEFootballResult, RecordEFootballResultError(..))
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
import Domain.Tournament
  ( Tournament(..), TournamentName(..), OrganizerName(..)
  , TournamentFormat(..), Visibility(..), ParticipantMode(..) )
import Shell.Persistence.Port (NewTournament(..))
import qualified Application.UseCases.CreateTournament as Create
import Engine.TournamentValidation
  (TournamentValidationError(..), ParticipantValidationError(..))
import Domain.Registration (RegistrationId(..))
import qualified Application.UseCases.RegisterParticipant as Register
import Data.IORef (IORef, newIORef, readIORef, atomicModifyIORef')
import qualified Data.Map.Strict as Map
import qualified Data.ByteString as BS
import Numeric (showHex)
import System.Entropy (getEntropy)
import Shell.Persistence.SQLite.UserRepository ()
import Shell.Infrastructure.PasswordHasher ()
import qualified Application.UseCases.LoginUser as LU
import Domain.User (User(..), Username(..), Email(..), AccountStatus(..))
import qualified Application.UseCases.RegisterUser as RU
import Engine.User (UserError(..))
import qualified Application.UseCases.GetTournament as GetT
import qualified Application.UseCases.ListMyTournaments as ListMine
import qualified Application.UseCases.StartTournament as StartT
import qualified Application.UseCases.CompleteTournament as Complete
import qualified Application.UseCases.CancelTournament as Cancel
import Domain.TournamentError (TournamentError(..))
import qualified Application.UseCases.ListPublicTournaments as ListPublic
import qualified Application.UseCases.UpdateTournamentThirdPlaceMatch as UTTP
import Shell.Persistence.SQLite.Connection (SQLiteM, SQLiteEnv(envConnection), runSQLiteM)
import Shell.Persistence.SQLite.Schema (initializeSchema)
import Control.Monad.Reader (ask)
import Domain.Bracket (Bracket(..), BracketNode(..), MatchSlot(..))
import Shell.Persistence.SQLite.EFootballScoreRepository ()
import Domain.Participant (Participant(..), Player(..), PlayerName(..), Team(..), TeamName(..))
import qualified Application.UseCases.CreateTeam as CT
import Application.UseCases.CreateTeam (createTeam, CreateTeamError(..))
import Application.UseCases.CreateTeam (createTeam, CreateTeamError(..))


dbPath :: FilePath
dbPath = "arenaos-dev.db"

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

recordViaApi :: UserId -> MatchId -> OutcomeReq
             -> SQLiteM (Either Record.RecordMatchResultError Match)
recordViaApi uid mid req = do
  m <- Repo.getMatch mid
  Record.recordMatchResult uid mid (toOutcome m req)

slotJson :: MatchSlot -> Value
slotJson (Filled p) =
  object ["type" .= ("Filled" :: Text), "participant" .= participantJson p]
slotJson (AwaitingWinnerOf n) =
  object ["type" .= ("AwaitingWinnerOf" :: Text), "node" .= unBracketNodeId n]
slotJson (AwaitingLoserOf n) =
  object ["type" .= ("AwaitingLoserOf" :: Text), "node" .= unBracketNodeId n]
slotJson ByeSlot =
  object ["type" .= ("Bye" :: Text)]

nodeJson :: [Match] -> BracketNode -> Value
nodeJson matches n = object
  [ "nodeId" .= unBracketNodeId (nodeId n)
  , "round"  .= nodeRound n
  , "stage"  .= T.pack (show (nodeStage n))
  , "slotA"  .= slotJson (nodeSlotA n)
  , "slotB"  .= slotJson (nodeSlotB n)
  , "match"  .= fmap matchJson (find (\m -> matchBracketNode m == nodeId n) matches)
  ]

bracketViewJson :: GetB.BracketView -> Value
bracketViewJson v = object
  [ "tournamentId"     .= unTournamentId (tournamentId t)
  , "format"           .= T.pack (show (tournamentFormat t))
  , "bracketId"        .= fmap unBracketId (tournamentBracket t)
  , "thirdPlaceNodeId" .= fmap unBracketNodeId (bracketThirdPlaceNodeId (GetB.viewBracket v))
  , "nodes"            .= map (nodeJson (GetB.viewMatches v)) sortedNodes
  ]
  where
    t = GetB.viewTournament v
    sortedNodes = sortOn (\n -> (nodeRound n, unBracketNodeId (nodeId n)))
                         (GetB.viewNodes v)

fromGetBracket :: GetB.GetBracketError -> ApiError
fromGetBracket (GetB.Unauthorized a)    = fromAuthorization a
fromGetBracket GetB.BracketNotGenerated =
  ApiError status404 "BRACKET_NOT_GENERATED"
    "No bracket has been generated for this tournament yet" (object [])

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
    pure (CreateReq n org fmt vis m tp mode)
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
tournamentJson t = object
  [ "tournamentId"    .= unTournamentId (tournamentId t)
  , "name"            .= unTournamentName (tournamentName t)
  , "organizer"       .= unOrganizerName (tournamentOrganizer t)
  , "format"          .= T.pack (show (tournamentFormat t))
  , "state"           .= T.pack (show (tournamentState t))
  , "visibility"      .= T.pack (show (tournamentVisibility t))
  , "maxParticipants" .= tournamentMaxParticipants t
  , "thirdPlaceMatch" .= tournamentThirdPlaceMatch t
  , "participantMode" .= T.pack (show (tournamentParticipantMode t))
  , "bracketId"       .= fmap unBracketId (tournamentBracket t)
  ]



tournamentViewJson :: GetT.TournamentView -> Value
tournamentViewJson v = object
  [ "tournament"    .= tournamentJson (GetT.tvTournament v)
  , "participants"  .= map participantJson (GetT.tvParticipants v)
  , "viewerIsOwner" .= GetT.tvViewerIsOwner v
  ]

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
    "The final match has not been decided yet" (object [])
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


data Env = Env
  { envLock   :: MVar ()
  , envTokens :: IORef (Map.Map Text UserId)
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
      store <- liftIO (readIORef (envTokens env))
      case Map.lookup tok store of
        Nothing  -> pure Nothing
        Just uid -> do
          r <- liftIO (tryAny (withMVar (envLock env)
                 (\_ -> runSQLiteM dbPath (Repo.findUserById uid))))
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
  parseJSON = withObject "login" $ \o ->
    LoginReq <$> o .: "username" <*> o .: "password"

fromLogin :: LU.LoginUserError -> ApiError
fromLogin LU.InvalidCredentials =
  ApiError status401 "INVALID_CREDENTIALS" "Wrong username or password" (object [])
fromLogin (LU.AccountNotActive s) =
  ApiError status403 "ACCOUNT_NOT_ACTIVE" "This account cannot log in"
    (object ["status" .= show s])

data RegisterReq = RegisterReq Text Text Text

instance FromJSON RegisterReq where
  parseJSON = withObject "register" $ \o ->
    RegisterReq <$> o .: "username" <*> o .: "email" <*> o .: "password"

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

tryAny :: IO a -> IO (Either SomeException a)
tryAny = try

runUseCase :: Env -> SQLiteM a -> ActionM (Either ApiError a)
runUseCase lock action = do
  outcome <- liftIO (tryAny (withMVar (envLock lock) (\_ -> runSQLiteM dbPath action)))
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
  initResult <- runSQLiteM dbPath $ do
    env <- ask
    liftIO (initializeSchema (envConnection env))
  case initResult of
    Left err -> hPutStrLn stderr ("schema init failed: " ++ show err)
    Right () -> pure ()
  lock <- Env <$> newMVar () <*> newIORef Map.empty
  scotty 3000 $ do
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
                      (Create.createTournamentChecked (toNewTournament uid req))
                 --     (Create.createTournamentChecked (toNewTournament (UserId uid) req))
          case result of
            Left apiErr -> sendError apiErr
            Right (Left (Create.InvalidTournament v)) -> sendError (fromValidation v)
            Right (Right tid) -> do
              status status201
              json (object ["tournamentId" .= unTournamentId tid])
              
    post "/tournaments/:id/registrations" $ do
      raw <- body
      case eitherDecode raw of
        Left reason -> sendError (invalidBody reason)
        Right req -> do
          resolved <- runUseCase lock (resolveParticipantReq req)
          case resolved of
            Left apiErr -> sendError apiErr
            Right p ->
              runAction lock
                (\uid tid -> Register.registerParticipantChecked uid tid p)
                fromRegister $ \rid -> do
                  status status201
                  json (object ["registrationId" .= unRegistrationId rid])

    post "/login" $ do
      raw <- body
      case eitherDecode raw of
        Left reason -> sendError (invalidBody reason)
        Right (LoginReq u p) -> do
          result <- runUseCase lock (LU.loginUser (LU.LoginUserRequest (Username u) p))
          case result of
            Left apiErr    -> sendError apiErr
            Right (Left e) -> sendError (fromLogin e)
            Right (Right user) -> do
              tok <- liftIO newToken
              liftIO (atomicModifyIORef' (envTokens lock)
                        (\m -> (Map.insert tok (userId user) m, ())))
              let Username uname = username user
              json (object [ "token" .= tok
                           , "user"  .= object [ "id"       .= unUserId (userId user)
                                               , "username" .= uname ] ])

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
        Right (RegisterReq u e p) -> do
          result <- runUseCase lock
            (RU.registerUser (RU.RegisterUserRequest (Username u) (Email e) p))
          case result of
            Left apiErr      -> sendError apiErr
            Right (Left err) -> sendError (fromRegisterUser err)
            Right (Right user) -> do
              status status201
              let Username uname = username user
              json (object [ "id" .= unUserId (userId user)
                           , "username" .= uname ])
    
    get "/me/tournaments" $ do
      mUser <- currentUser lock
      case mUser of
        Nothing  -> sendError unauthenticated
        Just uid -> do
          result <- runUseCase lock (ListMine.listMyTournaments uid)
          case result of
            Left apiErr -> sendError apiErr
            Right ts    -> json (object
              [ "tournaments" .=
                  map tournamentJson (sortOn (negate . unTournamentId . tournamentId) ts) ])
    
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
      runViewAction lock GetB.getBracket fromGetBracket $ \v ->
        json (bracketViewJson v)

    get "/tournaments/:id" $
      runViewAction lock GetT.getTournament fromGetTournament $ \v ->
        json (tournamentViewJson v)

    get "/tournaments" $ do
      mv <- viewer lock
      case mv of
        Left err -> sendError err
        Right _  -> do
          result <- runUseCase lock ListPublic.listPublicTournaments
          case result of
            Left apiErr -> sendError apiErr
            Right ts    -> json (object ["tournaments" .= map tournamentJson ts])

    post "/tournaments/:id/third-place-match" $ do
      raw <- body
      case eitherDecode raw of
        Left reason -> sendError (invalidBody reason)
        Right (ThirdPlaceMatchReq tp) ->
          runTransition lock
            (\uid tid -> UTTP.updateTournamentThirdPlaceMatch uid tid tp) fromUpdateThirdPlaceMatch

    post "/teams" $ do
      mUser <- currentUser lock
      raw   <- body
      case (mUser, eitherDecode raw) of
        (Nothing, _) -> sendError unauthenticated
        (_, Left reason) -> sendError (invalidBody reason)
        (Just _, Right req) -> do
          let team = toTeam req
          result <- runUseCase lock (createTeam team)
          case result of
            Left apiErr -> sendError apiErr
            Right (Left teamErr) -> sendError (fromCreateTeam teamErr)
            Right (Right ()) -> do
              status status201
              json (teamJson team)

              

    notFound $ sendError
      (ApiError status404 "ROUTE_NOT_FOUND" "No such endpoint" (object []))