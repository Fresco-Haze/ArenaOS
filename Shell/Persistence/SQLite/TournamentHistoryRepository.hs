{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}
-- Shell.Persistence.SQLite.TournamentHistoryRepository

module Shell.Persistence.SQLite.TournamentHistoryRepository () where

import Control.Exception (throwIO)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)

import Database.SQLite.Simple (Only(..), execute, query)

import Domain.Ids (TournamentId(..))
import Domain.TournamentHistory
    ( TournamentHistoryEvent(..)
    , TournamentHistoryEntry(..)
    , ChangedField(..)
    )

import Shell.Persistence.Port (TournamentHistoryRepository(..))
import Shell.Persistence.SQLite.Connection (SQLiteEnv(..), SQLiteM)
import Shell.Persistence.SQLite.Error (PersistenceError(..))

changedFieldToText :: ChangedField -> String
changedFieldToText FieldName            = "Name"
changedFieldToText FieldVisibility      = "Visibility"
changedFieldToText FieldFormat          = "Format"
changedFieldToText FieldMaxParticipants = "MaxParticipants"

textToChangedField :: String -> IO ChangedField
textToChangedField "Name"            = pure FieldName
textToChangedField "Visibility"      = pure FieldVisibility
textToChangedField "Format"          = pure FieldFormat
textToChangedField "MaxParticipants" = pure FieldMaxParticipants
textToChangedField other             =
    throwIO (StorageFailure ("Unknown changed field in storage: " ++ other))

eventToRow :: TournamentHistoryEvent -> (String, Maybe String, Maybe String)
eventToRow TournamentCreated            = ("TournamentCreated", Nothing, Nothing)
eventToRow TournamentPublished          = ("TournamentPublished", Nothing, Nothing)
eventToRow RegistrationOpened           = ("RegistrationOpened", Nothing, Nothing)
eventToRow RegistrationClosedEvent      = ("RegistrationClosed", Nothing, Nothing)
eventToRow BracketGenerated             = ("BracketGenerated", Nothing, Nothing)
eventToRow TournamentStarted            = ("TournamentStarted", Nothing, Nothing)
eventToRow TournamentCompleted          = ("TournamentCompleted", Nothing, Nothing)
eventToRow (TournamentCancelled reason) = ("TournamentCancelled", Just reason, Nothing)
eventToRow (ConfigurationChanged field) = ("ConfigurationChanged", Nothing, Just (changedFieldToText field))

rowToEvent :: String -> Maybe String -> Maybe String -> IO TournamentHistoryEvent
rowToEvent "TournamentCreated"   _ _ = pure TournamentCreated
rowToEvent "TournamentPublished" _ _ = pure TournamentPublished
rowToEvent "RegistrationOpened"  _ _ = pure RegistrationOpened
rowToEvent "RegistrationClosed"  _ _ = pure RegistrationClosedEvent
rowToEvent "BracketGenerated"    _ _ = pure BracketGenerated
rowToEvent "TournamentStarted"   _ _ = pure TournamentStarted
rowToEvent "TournamentCompleted" _ _ = pure TournamentCompleted
rowToEvent "TournamentCancelled" (Just reason) _ = pure (TournamentCancelled reason)
rowToEvent "TournamentCancelled" Nothing _ =
    throwIO (StorageFailure "TournamentCancelled row missing cancellation_reason")
rowToEvent "ConfigurationChanged" _ (Just fieldText) = do
    field <- textToChangedField fieldText
    pure (ConfigurationChanged field)
rowToEvent "ConfigurationChanged" _ Nothing =
    throwIO (StorageFailure "ConfigurationChanged row missing changed_field")
rowToEvent other _ _ =
    throwIO (StorageFailure ("Unknown tournament history event type in storage: " ++ other))

instance TournamentHistoryRepository SQLiteM where

    recordHistoryEvent :: TournamentId -> TournamentHistoryEvent -> SQLiteM ()
    recordHistoryEvent (TournamentId tidInt) event = do
        conn <- asks envConnection
        let (eventType, reason, field) = eventToRow event
        liftIO $ execute conn
            "INSERT INTO tournament_history (tournament_id, event_type, cancellation_reason, changed_field) \
            \VALUES (?, ?, ?, ?)"
            (tidInt, eventType, reason, field)

    getTournamentHistory :: TournamentId -> SQLiteM [TournamentHistoryEntry]
    getTournamentHistory (TournamentId tidInt) = do
        conn <- asks envConnection
        rows <- liftIO $
            (query conn
                "SELECT id, event_type, cancellation_reason, changed_field \
                \FROM tournament_history WHERE tournament_id = ? ORDER BY id ASC"
                (Only tidInt)
             :: IO [(Int, String, Maybe String, Maybe String)])
        mapM decodeRow rows
      where
        decodeRow (entryId, eventType, reason, field) = do
            event <- liftIO $ rowToEvent eventType reason field
            pure TournamentHistoryEntry
                { historyEntryId      = entryId
                , historyTournamentId = TournamentId tidInt
                , historyEvent        = event
                }