-- Domain.TournamentHistory
-- Pure data types only, zero logic (Architecture.md: Domain layer).
module Domain.TournamentHistory
    ( TournamentHistoryEvent(..)
    , ChangedField(..)
    , TournamentHistoryEntry(..)
    , ActivityItem(..)
    ) where

import Domain.Ids (TournamentId(..))

data ChangedField
    = FieldName
    | FieldVisibility
    | FieldFormat
    | FieldMaxParticipants
    | FieldThirdPlaceMatch
    | FieldGame
    | FieldStartTime
    | FieldPrize
    | FieldDescription
    deriving (Show, Eq)

data TournamentHistoryEvent
    = TournamentCreated
    | TournamentPublished
    | RegistrationOpened
    | RegistrationClosedEvent
    | BracketGenerated
    | TournamentStarted
    | TournamentCompleted
    | TournamentCancelled
        { cancellationReason :: String
        }
    | TournamentPaused
    | TournamentResumed
    | ConfigurationChanged
        { changedField :: ChangedField
        }
    | TournamentReopened
        { reopeningReason :: String
        }
    deriving (Show, Eq)

data TournamentHistoryEntry = TournamentHistoryEntry
    { historyEntryId      :: Int
    , historyTournamentId :: TournamentId
    , historyEvent        :: TournamentHistoryEvent
    } deriving (Show, Eq)

-- One line of the public activity feed. The time is canonical UTC text
-- (YYYY-MM-DDTHH:MM:SSZ) written by SQLite itself.
data ActivityItem = ActivityItem
    { activityTournamentId   :: TournamentId
    , activityTournamentName :: String
    , activityEvent          :: TournamentHistoryEvent
    , activityAt             :: String
    } deriving (Show, Eq)