{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- Shell.Persistence.SQLite.TournamentRepository

module Shell.Persistence.SQLite.TournamentRepository () where

import Control.Exception (throwIO)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)

import Database.SQLite.Simple (Only(..), changes, execute, query, lastInsertRowId, query_)

import Domain.Tournament
    ( Tournament(..)
    , TournamentId(..)
    , TournamentName(..)
    , OrganizerName(..)
    , TournamentFormat(..)
    , TournamentState(..)
    , Visibility(..)
    , BracketId(..)
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
stateToText Completed         = "Completed"
stateToText Cancelled         = "Cancelled"

textToState :: String -> IO TournamentState
textToState "Draft"              = pure Draft
textToState "Published"          = pure Published
textToState "RegistrationOpen"   = pure RegistrationOpen
textToState "RegistrationClosed" = pure RegistrationClosed
textToState "InProgress"         = pure InProgress
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

textToChangedField :: String -> IO ChangedField
textToChangedField "Name"             = pure FieldName
textToChangedField "Visibility"       = pure FieldVisibility
textToChangedField "Format"           = pure FieldFormat
textToChangedField "MaxParticipants"  = pure FieldMaxParticipants
textToChangedField other              =
    throwIO (StorageFailure ("Unknown changed field in storage: " ++ other))

instance TournamentRepository SQLiteM where

    createTournament :: NewTournament -> SQLiteM TournamentId
    createTournament nt = do
        conn <- asks envConnection
        let TournamentName tname    = newTournamentName nt
            OrganizerName organizer = newTournamentOrganizer nt
            UserId owner = newTournamentOwner nt
        liftIO $ execute conn
            "INSERT INTO tournaments (name, organizer_name, owner_id, format, state, visibility, max_participants, bracket_id) \
            \VALUES (?, ?, ?, ?, ?, ?, ?, NULL)"
            ( tname
            , organizer
            , owner 
            , formatToText (newTournamentFormat nt)
            , stateToText Draft
            , visibilityToText (newTournamentVisibility nt)
            , newTournamentMaxParticipants nt
            )
        rowId <- liftIO $ lastInsertRowId conn
        pure (TournamentId (fromIntegral rowId))

    getTournament :: TournamentId -> SQLiteM Tournament
    getTournament tid@(TournamentId tidInt) = do
        conn <- asks envConnection
        rows <- liftIO $
            (query conn
                "SELECT name, organizer_name,owner_id, format, state, visibility, max_participants, bracket_id \
                \FROM tournaments WHERE id = ?"
                (Only tidInt)
             :: IO [(String, String, Int,String, String, String, Int, Maybe Int)])
        case rows of
            [(name, organizer, owner_id, formatText, stateText, visText, maxP, bracketIdMaybe)] -> do
                format <- liftIO $ textToFormat formatText
                state  <- liftIO $ textToState stateText
                vis    <- liftIO $ textToVisibility visText
                pure Tournament
                    { tournamentId              = tid
                    , tournamentName            = TournamentName name
                    , tournamentOrganizer       = OrganizerName organizer
                    , tournamentOwner           = UserId  owner_id
                    , tournamentFormat          = format
                    , tournamentState           = state
                    , tournamentVisibility      = vis
                    , tournamentMaxParticipants = maxP
                    , tournamentBracket         = BracketId <$> bracketIdMaybe
                    }
            [] -> liftIO $ throwIO (NotFound ("Tournament not found: " ++ show tidInt))
            _  -> liftIO $ throwIO (StorageFailure ("Multiple tournaments with id " ++ show tidInt))

    saveTournament :: Tournament -> SQLiteM ()
    saveTournament t = do
        conn <- asks envConnection
        let TournamentId tidInt     = tournamentId t
            TournamentName tname    = tournamentName t
            OrganizerName organizer = tournamentOrganizer t
            UserId owner_id           = tournamentOwner t
            bracketIdMaybe          = (\(BracketId bid) -> bid) <$> tournamentBracket t
        liftIO $ execute conn
            "INSERT INTO tournaments (id, name, organizer_name, owner_id, format, state, visibility, max_participants, bracket_id) \
            \VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) \
            \ON CONFLICT(id) DO UPDATE SET \
            \  name = excluded.name, \
            \  organizer_name = excluded.organizer_name, \
            \  owner_id = excluded.owner_id, \
            \  format = excluded.format, \
            \  state = excluded.state, \
            \  visibility = excluded.visibility, \
            \  max_participants = excluded.max_participants, \
            \  bracket_id = excluded.bracket_id"
            ( tidInt
            , tname
            , organizer
            , owner_id
            , formatToText (tournamentFormat t)
            , stateToText (tournamentState t)
            , visibilityToText (tournamentVisibility t)
            , tournamentMaxParticipants t
            , bracketIdMaybe
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
         (query conn
            "SELECT id, name, organizer_name, owner_id, format, state, visibility, max_participants, bracket_id \
            \FROM tournaments WHERE owner_id = ?"
            (Only ownerId)
         :: IO [(Int, String, String, Int, String, String, String, Int, Maybe Int)])
        mapM decodeRow rows
     where
      decodeRow (tidInt, name, organizer, owner_id, formatText, stateText, visText, maxP, bracketIdMaybe) = do
        format <- liftIO $ textToFormat formatText
        state  <- liftIO $ textToState stateText
        vis    <- liftIO $ textToVisibility visText
        pure Tournament
            { tournamentId              = TournamentId tidInt
            , tournamentName            = TournamentName name
            , tournamentOrganizer       = OrganizerName organizer
            , tournamentOwner           = UserId owner_id
            , tournamentFormat          = format
            , tournamentState           = state
            , tournamentVisibility      = vis
            , tournamentMaxParticipants = maxP
            , tournamentBracket         = BracketId <$> bracketIdMaybe
            }

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
        rows <- liftIO $
         (query_ conn
            "SELECT id, name, organizer_name, owner_id, format, state, visibility, max_participants, bracket_id \
            \FROM tournaments"
         :: IO [(Int, String, String, Int, String, String, String, Int, Maybe Int)])
        mapM decodeRow rows
     where
      decodeRow (tidInt, name, organizer, owner_id, formatText, stateText, visText, maxP, bracketIdMaybe) = do
        format <- liftIO $ textToFormat formatText
        state  <- liftIO $ textToState stateText
        vis    <- liftIO $ textToVisibility visText
        pure Tournament
            { tournamentId              = TournamentId tidInt
            , tournamentName            = TournamentName name
            , tournamentOrganizer       = OrganizerName organizer
            , tournamentOwner           = UserId owner_id
            , tournamentFormat          = format
            , tournamentState           = state
            , tournamentVisibility      = vis
            , tournamentMaxParticipants = maxP
            , tournamentBracket         = BracketId <$> bracketIdMaybe
            }
