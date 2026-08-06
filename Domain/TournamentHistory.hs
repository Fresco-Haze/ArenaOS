-- Domain.TournamentHistory
-- Pure data types only, zero logic (Architecture.md: Domain layer).
module Domain.TournamentHistory
    ( TournamentHistoryEvent(..)
    , ChangedField(..)
    , TournamentHistoryEntry(..)
    ) where

import Domain.Ids (TournamentId(..))

data ChangedField
    = FieldName
    | FieldVisibility
    | FieldFormat
    | FieldMaxParticipants
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
    | ConfigurationChanged
        { changedField :: ChangedField
        }
    deriving (Show, Eq)

data TournamentHistoryEntry = TournamentHistoryEntry
    { historyEntryId      :: Int
    , historyTournamentId :: TournamentId
    , historyEvent        :: TournamentHistoryEvent
    } deriving (Show, Eq)