{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- Shell.Persistence.SQLite.TournamentRepository

module Shell.Persistence.SQLite.TournamentRepository () where

import Control.Exception (throwIO)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)

import Database.SQLite.Simple (Only(..), changes, execute, query, lastInsertRowId)

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

import Shell.Persistence.Port (TournamentRepository(..), NewTournament(..))
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

instance TournamentRepository SQLiteM where

    createTournament :: NewTournament -> SQLiteM TournamentId
    createTournament nt = do
        conn <- asks envConnection
        let TournamentName tname    = newTournamentName nt
            OrganizerName organizer = newTournamentOrganizer nt
        liftIO $ execute conn
            "INSERT INTO tournaments (name, organizer_name, format, state, visibility, max_participants, bracket_id) \
            \VALUES (?, ?, ?, ?, ?, ?, NULL)"
            ( tname
            , organizer
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
                "SELECT name, organizer_name, format, state, visibility, max_participants, bracket_id \
                \FROM tournaments WHERE id = ?"
                (Only tidInt)
             :: IO [(String, String, String, String, String, Int, Maybe Int)])
        case rows of
            [(name, organizer, formatText, stateText, visText, maxP, bracketIdMaybe)] -> do
                format <- liftIO $ textToFormat formatText
                state  <- liftIO $ textToState stateText
                vis    <- liftIO $ textToVisibility visText
                pure Tournament
                    { tournamentId              = tid
                    , tournamentName            = TournamentName name
                    , tournamentOrganizer       = OrganizerName organizer
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
            bracketIdMaybe          = (\(BracketId bid) -> bid) <$> tournamentBracket t
        liftIO $ execute conn
            "INSERT INTO tournaments (id, name, organizer_name, format, state, visibility, max_participants, bracket_id) \
            \VALUES (?, ?, ?, ?, ?, ?, ?, ?) \
            \ON CONFLICT(id) DO UPDATE SET \
            \  name = excluded.name, \
            \  organizer_name = excluded.organizer_name, \
            \  format = excluded.format, \
            \  state = excluded.state, \
            \  visibility = excluded.visibility, \
            \  max_participants = excluded.max_participants, \
            \  bracket_id = excluded.bracket_id"
            ( tidInt
            , tname
            , organizer
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