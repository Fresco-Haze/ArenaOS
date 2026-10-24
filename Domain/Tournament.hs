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
    , ParticipantMode(..)
    , Game(..)
    , TournamentDetails(..)
    , noDetails
    , PublicStats(..)
    ) where

import Data.Time (UTCTime)
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
    | InProgress | Paused | Completed | Cancelled
    deriving (Show, Eq)

data TournamentFormat = SingleElimination | DoubleElimination | RoundRobin
    deriving (Show, Eq)

data Visibility = Public | Private deriving (Show, Eq)

-- v0.12: optional tournament tag. Stored as text; see Schema CHECK.
data Game = GameEFootball | GamePubgMobile | GameCallOfDuty | GameOther
    deriving (Show, Eq)

-- v0.12: optional, organizer-editable descriptive fields.
-- startTime is the scheduled start (UTC); it never starts the tournament.
data TournamentDetails = TournamentDetails
    { detailsGame      :: Maybe Game
    , detailsStartTime :: Maybe UTCTime
    , detailsPrize     :: Maybe Int
    , detailsDescription :: Maybe String
    } deriving (Show, Eq)

noDetails :: TournamentDetails
noDetails = TournamentDetails Nothing Nothing Nothing Nothing

-- v0.12: public counts for the home page. "Public" means visibility Public
-- and past Draft, the same set the public list shows.
data PublicStats = PublicStats
    { statsTournaments       :: Int
    , statsActiveTournaments :: Int
    , statsPlayers           :: Int
    , statsTeams             :: Int
    , statsPrizePool         :: Int
    , statsByGame            :: [(Game, Int)]
    } deriving (Show, Eq)

data ParticipantMode = IndividualOnly | SquadOnly
    deriving (Show, Eq)



data Tournament = Tournament
    { tournamentId :: TournamentId
    , tournamentName :: TournamentName
    , tournamentOrganizer :: OrganizerName
    , tournamentFormat :: TournamentFormat
    , tournamentState :: TournamentState
    , tournamentVisibility :: Visibility
    , tournamentMaxParticipants :: Int
    , tournamentThirdPlaceMatch :: Bool
    , tournamentBracket :: Maybe BracketId
    , tournamentOwner :: UserId
    , tournamentParticipantMode :: ParticipantMode
    , tournamentGame :: Maybe Game
    , tournamentStartTime :: Maybe UTCTime
    , tournamentPrize :: Maybe Int
    , tournamentDescription :: Maybe String
    , tournamentRequireApproval :: Bool
    } deriving (Show, Eq)

