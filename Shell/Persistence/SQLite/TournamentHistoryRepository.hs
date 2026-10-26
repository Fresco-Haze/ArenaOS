{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}
-- Shell.Persistence.SQLite.TournamentHistoryRepository

module Shell.Persistence.SQLite.TournamentHistoryRepository () where

import Control.Exception (throwIO)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)

import Database.SQLite.Simple (Only(..), execute, query)

import Domain.Ids (TournamentId(..), UserId(..))
import Domain.TournamentHistory
    ( TournamentHistoryEvent(..)
    , TournamentHistoryEntry(..)
    , ChangedField(..)
    , ActivityItem(..)
    )

import Shell.Persistence.Port (TournamentHistoryRepository(..))
import Shell.Persistence.SQLite.Connection (SQLiteEnv(..), SQLiteM)
import Shell.Persistence.SQLite.Error (PersistenceError(..))

changedFieldToText :: ChangedField -> String
changedFieldToText FieldName            = "Name"
changedFieldToText FieldVisibility      = "Visibility"
changedFieldToText FieldFormat          = "Format"
changedFieldToText FieldMaxParticipants = "MaxParticipants"
changedFieldToText FieldThirdPlaceMatch = "ThirdPlaceMatch"
changedFieldToText FieldGame            = "Game"
changedFieldToText FieldStartTime       = "StartTime"
changedFieldToText FieldPrize           = "Prize"
changedFieldToText FieldDescription      = "Description"
changedFieldToText FieldRegistrationDeadline = "RegistrationDeadline"
changedFieldToText FieldEntryFee = "EntryFee"
changedFieldToText FieldPlatform = "Platform"
changedFieldToText FieldRules = "Rules"

textToChangedField :: String -> IO ChangedField
textToChangedField "Name"            = pure FieldName
textToChangedField "Visibility"      = pure FieldVisibility
textToChangedField "Format"          = pure FieldFormat
textToChangedField "MaxParticipants" = pure FieldMaxParticipants
textToChangedField "ThirdPlaceMatch" = pure FieldThirdPlaceMatch
textToChangedField "Game"            = pure FieldGame
textToChangedField "StartTime"       = pure FieldStartTime
textToChangedField "Prize"           = pure FieldPrize
textToChangedField "Description"      = pure FieldDescription
textToChangedField "RegistrationDeadline" = pure FieldRegistrationDeadline
textToChangedField "EntryFee" = pure FieldEntryFee
textToChangedField "Platform" = pure FieldPlatform
textToChangedField "Rules" = pure FieldRules
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
eventToRow (TournamentReopened reason) = ("TournamentReopened", Just reason, Nothing)
eventToRow TournamentPaused  = ("TournamentPaused", Nothing, Nothing)
eventToRow TournamentResumed = ("TournamentResumed", Nothing, Nothing)

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
rowToEvent "TournamentReopened" (Just reason) _ = pure (TournamentReopened reason)
rowToEvent "TournamentReopened" Nothing _ =
    throwIO (StorageFailure "TournamentReopened row missing reopening_reason")
rowToEvent "TournamentPaused"  _ _ = pure TournamentPaused
rowToEvent "TournamentResumed" _ _ = pure TournamentResumed
rowToEvent other _ _ =
    throwIO (StorageFailure ("Unknown tournament history event type in storage: " ++ other))

instance TournamentHistoryRepository SQLiteM where

    recordHistoryEvent :: TournamentId -> TournamentHistoryEvent -> SQLiteM ()
    recordHistoryEvent (TournamentId tidInt) event = do
        conn <- asks envConnection
        let (eventType, reason, field) = eventToRow event
        liftIO $ execute conn
            "INSERT INTO tournament_history (tournament_id, event_type, cancellation_reason, changed_field, occurred_at) \
            \VALUES (?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))"
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

    recentPublicActivity :: Int -> SQLiteM [ActivityItem]
    recentPublicActivity limitN = do
        conn <- asks envConnection
        rows <- liftIO $
            (query conn
                "SELECT h.tournament_id, t.name, h.event_type, h.cancellation_reason, h.changed_field, h.occurred_at \
                \FROM tournament_history h JOIN tournaments t ON t.id = h.tournament_id \
                \WHERE t.visibility = 'Public' AND t.state <> 'Draft' \
                \AND h.occurred_at IS NOT NULL \
                \AND h.event_type IN ('TournamentPublished', 'RegistrationOpened', 'TournamentStarted', \
                \                     'TournamentCompleted', 'TournamentCancelled', 'TournamentReopened') \
                \ORDER BY h.occurred_at DESC, h.id DESC LIMIT ?"
                (Only limitN)
             :: IO [(Int, String, String, Maybe String, Maybe String, String)])
        liftIO (mapM decodeItem rows)
      where
        decodeItem (tid, name, eventType, reason, field, at) = do
            event <- rowToEvent eventType reason field
            pure ActivityItem
                { activityTournamentId   = TournamentId tid
                , activityTournamentName = name
                , activityEvent          = event
                , activityAt             = at
                }

    recentOwnerActivity :: UserId -> Int -> SQLiteM [ActivityItem]
    recentOwnerActivity (UserId uidInt) limitN = do
        conn <- asks envConnection
        rows <- liftIO $
            (query conn
                "SELECT h.tournament_id, t.name, h.event_type, h.cancellation_reason, h.changed_field, h.occurred_at \
                \FROM tournament_history h JOIN tournaments t ON t.id = h.tournament_id \
                \WHERE t.owner_id = ? \
                \AND h.occurred_at IS NOT NULL \
                \AND h.event_type IN ('TournamentPublished', 'RegistrationOpened', 'TournamentStarted', \
                \                     'TournamentCompleted', 'TournamentCancelled', 'TournamentReopened') \
                \ORDER BY h.occurred_at DESC, h.id DESC LIMIT ?"
                (uidInt, limitN)
             :: IO [(Int, String, String, Maybe String, Maybe String, String)])
        liftIO (mapM decodeOwnerItem rows)
      where
        decodeOwnerItem (tid, name, eventType, reason, field, at) = do
            event <- rowToEvent eventType reason field
            pure ActivityItem
                { activityTournamentId   = TournamentId tid
                , activityTournamentName = name
                , activityEvent          = event
                , activityAt             = at
                }