-- Domain.Tournament
-- Pure data types only, zero logic (Architecture.md: Domain layer).
-- Transcribed from Document 3 (Domain Model, Core Types).
module Domain.Tournament
    ( TournamentId(..)
    , TournamentName(..)
    , OrganizerName(..)
    , TournamentFormat(..)
    , TournamentState(..)
    , Visibility(..)
    , BracketId(..)
    , Tournament(..)
    ) where

import Domain.Ids (TournamentId(..), BracketId(..),UserId(..))


newtype TournamentName = TournamentName {unTournamentName :: String} deriving (Show, Eq)
newtype OrganizerName = OrganizerName {unOrganizerName :: String} deriving (Show, Eq)

-- TODO:
-- BracketId is temporarily defined here because Domain.Bracket
-- has not been introduced yet. Revisit ownership once Bracket.hs
-- exists -- either move it there, or, if enough shared Core Types
-- accumulate to justify it, into a Domain.Core module. Not done now
-- per the discover-repetition-first principle.

data TournamentState
    = Draft | Published | RegistrationOpen | RegistrationClosed
    | InProgress | Completed | Cancelled
    deriving (Show, Eq)

data TournamentFormat = SingleElimination | DoubleElimination | RoundRobin
    deriving (Show, Eq)

data Visibility = Public | Private deriving (Show, Eq)

data Tournament = Tournament
    { tournamentId :: TournamentId
    , tournamentName :: TournamentName
    , tournamentOrganizer :: OrganizerName
    , tournamentFormat :: TournamentFormat
    , tournamentState :: TournamentState
    , tournamentVisibility :: Visibility
    , tournamentMaxParticipants :: Int
    , tournamentBracket :: Maybe BracketId
    , tournamentOwner :: UserId
    } deriving (Show, Eq)