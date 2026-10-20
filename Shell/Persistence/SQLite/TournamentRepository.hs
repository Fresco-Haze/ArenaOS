{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeOperators #-}
-- Shell.Persistence.SQLite.TournamentRepository

module Shell.Persistence.SQLite.TournamentRepository () where

import Control.Exception (throwIO)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.Time (UTCTime, formatTime, defaultTimeLocale, parseTimeM)

import Database.SQLite.Simple (Only(..), (:.)(..), Query, changes, execute, query, lastInsertRowId, query_)

import Domain.Tournament
    ( Tournament(..)
    , TournamentId(..)
    , TournamentName(..)
    , OrganizerName(..)
    , TournamentFormat(..)
    , TournamentState(..)
    , Visibility(..)
    , BracketId(..)
    , ParticipantMode(..)
    , Game(..)
    , TournamentDetails(..)
    )
import Domain.TournamentHistory (TournamentHistoryEvent(..), TournamentHistoryEntry(..), ChangedField(..))
import Shell.Persistence.Port (TournamentRepository(..), NewTournament(..),UserId(..))
import Shell.Persistence.SQLite.Connection (SQLiteEnv(..), SQLiteM)
import Shell.Persistence.SQLite.Error (PersistenceError(..))

-- Enum <-> Text conversion helpers, matching the manual-conversion
-- pattern used for Participant.kind in ParticipantRepository.hs
-- (see project discussion -- discovered repetition first, abstract
-- second; not yet worth ToField/FromField instances at one
-- repository's worth of usage).

formatToText :: TournamentFormat -> String
formatToText SingleElimination = "SingleElimination"
formatToText DoubleElimination = "DoubleElimination"
formatToText RoundRobin        = "RoundRobin"

textToFormat :: String -> IO TournamentFormat
textToFormat "SingleElimination" = pure SingleElimination
textToFormat "DoubleElimination" = pure DoubleElimination
textToFormat "RoundRobin"        = pure RoundRobin
textToFormat other               =
    throwIO (StorageFailure ("Unknown tournament format in storage: " ++ other))

stateToText :: TournamentState -> String
stateToText Draft             = "Draft"
stateToText Published         = "Published"
stateToText RegistrationOpen  = "RegistrationOpen"
stateToText RegistrationClosed = "RegistrationClosed"
stateToText InProgress        = "InProgress"
stateToText Paused            = "Paused"
stateToText Completed         = "Completed"
stateToText Cancelled         = "Cancelled"

textToState :: String -> IO TournamentState
textToState "Draft"              = pure Draft
textToState "Published"          = pure Published
textToState "RegistrationOpen"   = pure RegistrationOpen
textToState "RegistrationClosed" = pure RegistrationClosed
textToState "InProgress"         = pure InProgress
textToState "Paused"             = pure Paused
textToState "Completed"          = pure Completed
textToState "Cancelled"          = pure Cancelled
textToState other                =
    throwIO (StorageFailure ("Unknown tournament state in storage: " ++ other))

visibilityToText :: Visibility -> String
visibilityToText Public  = "Public"
visibilityToText Private = "Private"

textToVisibility :: String -> IO Visibility
textToVisibility "Public"  = pure Public
textToVisibility "Private" = pure Private
textToVisibility other     =
    throwIO (StorageFailure ("Unknown visibility in storage: " ++ other))

participantModeToText :: ParticipantMode -> String
participantModeToText IndividualOnly = "IndividualOnly"
participantModeToText SquadOnly      = "SquadOnly"

textToParticipantMode :: String -> IO ParticipantMode
textToParticipantMode "IndividualOnly" = pure IndividualOnly
textToParticipantMode "SquadOnly"      = pure SquadOnly
textToParticipantMode other            =
    throwIO (StorageFailure ("Unknown participant mode in storage: " ++ other))

-- v0.12. Values must match the CHECK on tournaments.game in Schema.hs.
gameToText :: Game -> String
gameToText GameEFootball   = "eFootball"
gameToText GamePubgMobile  = "PubgMobile"
gameToText GameCallOfDuty  = "CallOfDuty"
gameToText GameOther       = "Other"

textToGame :: String -> IO Game
textToGame "eFootball"  = pure GameEFootball
textToGame "PubgMobile" = pure GamePubgMobile
textToGame "CallOfDuty" = pure GameCallOfDuty
textToGame "Other"      = pure GameOther
textToGame other        =
    throwIO (StorageFailure ("Unknown game in storage: " ++ other))

-- Canonical UTC ISO 8601, whole seconds (same shape as matches.scheduled_start).
timeFormat :: String
timeFormat = "%Y-%m-%dT%H:%M:%SZ"

timeToText :: UTCTime -> String
timeToText = formatTime defaultTimeLocale timeFormat

textToTime :: String -> IO UTCTime
textToTime s =
    case (parseTimeM True defaultTimeLocale timeFormat s :: Maybe UTCTime) of
        Just t  -> pure t
        Nothing -> throwIO (StorageFailure ("Invalid start_time in storage: " ++ s))

eventToRow :: TournamentHistoryEvent -> (String, Maybe String, Maybe String)
eventToRow TournamentCreated               = ("TournamentCreated", Nothing, Nothing)
eventToRow TournamentPublished             = ("TournamentPublished", Nothing, Nothing)
eventToRow RegistrationOpened              = ("RegistrationOpened", Nothing, Nothing)
eventToRow RegistrationClosedEvent         = ("RegistrationClosed", Nothing, Nothing)
eventToRow BracketGenerated                = ("BracketGenerated", Nothing, Nothing)
eventToRow TournamentStarted               = ("TournamentStarted", Nothing, Nothing)
eventToRow TournamentCompleted             = ("TournamentCompleted", Nothing, Nothing)
eventToRow (TournamentCancelled reason)    = ("TournamentCancelled", Just reason, Nothing)
eventToRow (ConfigurationChanged field)    = ("ConfigurationChanged", Nothing, Just (changedFieldToText field))

rowToEvent :: String -> Maybe String -> Maybe String -> IO TournamentHistoryEvent
rowToEvent "TournamentCreated"    _ _ = pure TournamentCreated
rowToEvent "TournamentPublished"  _ _ = pure TournamentPublished
rowToEvent "RegistrationOpened"   _ _ = pure RegistrationOpened
rowToEvent "RegistrationClosed"   _ _ = pure RegistrationClosedEvent
rowToEvent "BracketGenerated"     _ _ = pure BracketGenerated
rowToEvent "TournamentStarted"    _ _ = pure TournamentStarted
rowToEvent "TournamentCompleted"  _ _ = pure TournamentCompleted
rowToEvent "TournamentCancelled" (Just reason) _ =
    pure (TournamentCancelled reason)
rowToEvent "TournamentCancelled" Nothing _ =
    throwIO (StorageFailure "TournamentCancelled row missing cancellation_reason")
rowToEvent "ConfigurationChanged" _ (Just fieldText) = do
    field <- textToChangedField fieldText
    pure (ConfigurationChanged field)
rowToEvent "ConfigurationChanged" _ Nothing =
    throwIO (StorageFailure "ConfigurationChanged row missing changed_field")
rowToEvent other _ _ =
    throwIO (StorageFailure ("Unknown tournament history event type in storage: " ++ other))

changedFieldToText :: ChangedField -> String
changedFieldToText FieldName             = "Name"
changedFieldToText FieldVisibility       = "Visibility"
changedFieldToText FieldFormat           = "Format"
changedFieldToText FieldMaxParticipants  = "MaxParticipants"
changedFieldToText FieldThirdPlaceMatch  = "ThirdPlaceMatch"
changedFieldToText FieldGame             = "Game"
changedFieldToText FieldStartTime        = "StartTime"
changedFieldToText FieldPrize            = "Prize"

textToChangedField :: String -> IO ChangedField
textToChangedField "Name"             = pure FieldName
textToChangedField "Visibility"       = pure FieldVisibility
textToChangedField "Format"           = pure FieldFormat
textToChangedField "MaxParticipants"  = pure FieldMaxParticipants
textToChangedField "ThirdPlaceMatch"  = pure FieldThirdPlaceMatch
textToChangedField "Game"             = pure FieldGame
textToChangedField "StartTime"        = pure FieldStartTime
textToChangedField "Prize"            = pure FieldPrize
textToChangedField other              =
    throwIO (StorageFailure ("Unknown changed field in storage: " ++ other))

intToThirdPlaceMatch :: Int -> Bool
intToThirdPlaceMatch 0 = False
intToThirdPlaceMatch _ = True

thirdPlaceMatchToInt :: Bool -> Int
thirdPlaceMatchToInt False = 0
thirdPlaceMatchToInt True  = 1

-- One SELECT and one decoder shared by getTournament and both list queries.
tournamentSelect :: Query
tournamentSelect =
    "SELECT id, name, organizer_name, owner_id, format, state, visibility, \
    \max_participants, third_place_match, bracket_id, \
    \participant_mode, game, start_time, prize \
    \FROM tournaments"

type TournamentRow =
    (Int, String, String, Int, String, String, String, Int, Int, Maybe Int)
    :. (String, Maybe String, Maybe String, Maybe String)

decodeTournamentRow :: TournamentRow -> IO Tournament
decodeTournamentRow
    ( (tidInt, name, organizer, ownerId, formatText, stateText, visText, maxP, thirdPlaceInt, bracketIdMaybe)
      :. (modeText, gameMaybe, startMaybe, prizeMaybe) ) = do
    format <- textToFormat formatText
    state  <- textToState stateText
    vis    <- textToVisibility visText
    mode   <- textToParticipantMode modeText
    game   <- traverse textToGame gameMaybe
    start  <- traverse textToTime startMaybe
    pure Tournament
        { tournamentId              = TournamentId tidInt
        , tournamentName            = TournamentName name
        , tournamentOrganizer       = OrganizerName organizer
        , tournamentOwner           = UserId ownerId
        , tournamentFormat          = format
        , tournamentState           = state
        , tournamentVisibility      = vis
        , tournamentMaxParticipants = maxP
        , tournamentThirdPlaceMatch = intToThirdPlaceMatch thirdPlaceInt
        , tournamentParticipantMode = mode
        , tournamentBracket         = BracketId <$> bracketIdMaybe
        , tournamentGame            = game
        , tournamentStartTime       = start
        , tournamentPrize           = prizeMaybe
        }

instance TournamentRepository SQLiteM where

    createTournament :: NewTournament -> SQLiteM TournamentId
    createTournament nt = do
        conn <- asks envConnection
        let TournamentName tname    = newTournamentName nt
            OrganizerName organizer = newTournamentOrganizer nt
            UserId owner = newTournamentOwner nt
        liftIO $ execute conn
            "INSERT INTO tournaments (name, organizer_name, owner_id, format, state, visibility, max_participants, third_place_match, participant_mode, bracket_id) \
            \VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)"
            ( tname
            , organizer
            , owner
            , formatToText (newTournamentFormat nt)
            , stateToText Draft
            , visibilityToText (newTournamentVisibility nt)
            , newTournamentMaxParticipants nt
            , thirdPlaceMatchToInt (newTournamentThirdPlaceMatch nt)
            , participantModeToText (newTournamentParticipantMode nt)
            )
        rowId <- liftIO $ lastInsertRowId conn
        pure (TournamentId (fromIntegral rowId))

    getTournament :: TournamentId -> SQLiteM Tournament
    getTournament (TournamentId tidInt) = do
        conn <- asks envConnection
        rows <- liftIO $
            (query conn (tournamentSelect <> " WHERE id = ?") (Only tidInt)
             :: IO [TournamentRow])
        case rows of
            [row] -> liftIO (decodeTournamentRow row)
            []    -> liftIO $ throwIO (NotFound ("Tournament not found: " ++ show tidInt))
            _     -> liftIO $ throwIO (StorageFailure ("Multiple tournaments with id " ++ show tidInt))

    saveTournament :: Tournament -> SQLiteM ()
    saveTournament t = do
        conn <- asks envConnection
        let TournamentId tidInt     = tournamentId t
            TournamentName tname    = tournamentName t
            OrganizerName organizer = tournamentOrganizer t
            UserId owner_id         = tournamentOwner t
            bracketIdMaybe          = (\(BracketId bid) -> bid) <$> tournamentBracket t
        liftIO $ execute conn
            "INSERT INTO tournaments (id, name, organizer_name, owner_id, format, state, visibility, max_participants, third_place_match, bracket_id, participant_mode, game, start_time, prize) \
            \VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) \
            \ON CONFLICT(id) DO UPDATE SET \
            \  name = excluded.name, \
            \  organizer_name = excluded.organizer_name, \
            \  owner_id = excluded.owner_id, \
            \  format = excluded.format, \
            \  state = excluded.state, \
            \  visibility = excluded.visibility, \
            \  max_participants = excluded.max_participants, \
            \  third_place_match = excluded.third_place_match, \
            \  bracket_id = excluded.bracket_id, \
            \  game = excluded.game, \
            \  start_time = excluded.start_time, \
            \  prize = excluded.prize"
            ( ( tidInt
              , tname
              , organizer
              , owner_id
              , formatToText (tournamentFormat t)
              , stateToText (tournamentState t)
              , visibilityToText (tournamentVisibility t)
              , tournamentMaxParticipants t
              , thirdPlaceMatchToInt (tournamentThirdPlaceMatch t)
              , bracketIdMaybe
              )
              :. ( participantModeToText (tournamentParticipantMode t)
                 , gameToText <$> tournamentGame t
                 , timeToText <$> tournamentStartTime t
                 , tournamentPrize t
                 )
            )

    deleteTournament :: TournamentId -> SQLiteM ()
    deleteTournament (TournamentId tidInt) = do
        conn <- asks envConnection
        liftIO $ execute conn
            "DELETE FROM tournaments WHERE id = ?"
            (Only tidInt)
        n <- liftIO $ changes conn
        when (n == 0) $
            liftIO $ throwIO (NotFound ("Tournament not found: " ++ show tidInt))

    listTournamentsByOwner :: UserId -> SQLiteM [Tournament]
    listTournamentsByOwner (UserId ownerId) = do
        conn <- asks envConnection
        rows <- liftIO $
            (query conn (tournamentSelect <> " WHERE owner_id = ?") (Only ownerId)
             :: IO [TournamentRow])
        liftIO (mapM decodeTournamentRow rows)

    updateTournamentState :: TournamentId -> TournamentState -> SQLiteM ()
    updateTournamentState (TournamentId tidInt) newState = do
        conn <- asks envConnection
        liftIO $ execute conn
            "UPDATE tournaments SET state = ? WHERE id = ?"
            (stateToText newState, tidInt)
        n <- liftIO $ changes conn
        when (n == 0) $
            liftIO $ throwIO (NotFound ("Tournament not found: " ++ show tidInt))

    updateTournamentName :: TournamentId -> TournamentName -> SQLiteM ()
    updateTournamentName (TournamentId tidInt) (TournamentName newName) = do
        conn <- asks envConnection
        liftIO $ execute conn
            "UPDATE tournaments SET name = ? WHERE id = ?"
            (newName, tidInt)
        n <- liftIO $ changes conn
        when (n == 0) $
            liftIO $ throwIO (NotFound ("Tournament not found: " ++ show tidInt))

    updateTournamentMaxParticipants :: TournamentId -> Int -> SQLiteM ()
    updateTournamentMaxParticipants (TournamentId tidInt) newMax = do
        conn <- asks envConnection
        liftIO $ execute conn
            "UPDATE tournaments SET max_participants = ? WHERE id = ?"
            (newMax, tidInt)
        n <- liftIO $ changes conn
        when (n == 0) $
            liftIO $ throwIO (NotFound ("Tournament not found: " ++ show tidInt))

    updateTournamentVisibility :: TournamentId -> Visibility -> SQLiteM ()
    updateTournamentVisibility (TournamentId tidInt) newVisibility = do
        conn <- asks envConnection
        liftIO $ execute conn
            "UPDATE tournaments SET visibility = ? WHERE id = ?"
            (visibilityToText newVisibility, tidInt)
        n <- liftIO $ changes conn
        when (n == 0) $
            liftIO $ throwIO (NotFound ("Tournament not found: " ++ show tidInt))

    updateTournamentFormat :: TournamentId -> TournamentFormat -> SQLiteM ()
    updateTournamentFormat (TournamentId tidInt) newFormat = do
        conn <- asks envConnection
        liftIO $ execute conn
            "UPDATE tournaments SET format = ? WHERE id = ?"
            (formatToText newFormat, tidInt)
        n <- liftIO $ changes conn
        when (n == 0) $
            liftIO $ throwIO (NotFound ("Tournament not found: " ++ show tidInt))

    listAllTournaments :: SQLiteM [Tournament]
    listAllTournaments = do
        conn <- asks envConnection
        rows <- liftIO $ (query_ conn tournamentSelect :: IO [TournamentRow])
        liftIO (mapM decodeTournamentRow rows)

    updateTournamentThirdPlaceMatch :: TournamentId -> Bool -> SQLiteM ()
    updateTournamentThirdPlaceMatch (TournamentId tidInt) newThirdPlaceMatch = do
        conn <- asks envConnection
        liftIO $ execute conn
            "UPDATE tournaments SET third_place_match = ? WHERE id = ?"
            (thirdPlaceMatchToInt newThirdPlaceMatch, tidInt)
        n <- liftIO $ changes conn
        when (n == 0) $
            liftIO $ throwIO (NotFound ("Tournament not found: " ++ show tidInt))

    updateTournamentDetails :: TournamentId -> TournamentDetails -> SQLiteM ()
    updateTournamentDetails (TournamentId tidInt) d = do
        conn <- asks envConnection
        liftIO $ execute conn
            "UPDATE tournaments SET game = ?, start_time = ?, prize = ? WHERE id = ?"
            ( gameToText <$> detailsGame d
            , timeToText <$> detailsStartTime d
            , detailsPrize d
            , tidInt
            )
        n <- liftIO $ changes conn
        when (n == 0) $
            liftIO $ throwIO (NotFound ("Tournament not found: " ++ show tidInt))