{-# LANGUAGE PatternSynonyms #-}
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
    , TournamentKind(..)
    , Game(GameEFootball, GamePubgMobile, GameCallOfDuty), mkGame, gameName, legacyGameName
    , TournamentDetails(..)
    , noDetails
    , PublicStats(..)
    ) where

import Data.Char (isControl, toLower)
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
-- v0.13: a game is a validated name (trimmed, 1 to 40 characters). Games are
-- data in the games table. Names compare ignoring case, like its NOCASE key.
newtype Game = Game String
    deriving (Show)

instance Eq Game where
    Game a == Game b = map toLower a == map toLower b

mkGame :: String -> Either String Game
mkGame raw
    | null s          = Left "game name is required"
    | length s > 40   = Left "game name must be 40 characters or fewer"
    | any isControl s = Left "game name has invalid characters"
    | otherwise       = Right (Game s)
  where s = unwords (words raw)

gameName :: Game -> String
gameName (Game s) = s

-- v0.13: old API values (PubgMobile, CallOfDuty, eFootball) still resolve to
-- the new names, so old links and old clients keep working. Any other text is
-- returned unchanged for mkGame to validate.
legacyGameName :: String -> String
legacyGameName raw = case map toLower (unwords (words raw)) of
    "pubgmobile" -> "PUBG Mobile"
    "callofduty" -> "Call of Duty"
    "efootball"  -> "eFootball"
    _            -> raw

-- Shortcuts for the three original games (keeps older code and tests readable).
pattern GameEFootball :: Game
pattern GameEFootball = Game "eFootball"

pattern GamePubgMobile :: Game
pattern GamePubgMobile = Game "PUBG Mobile"

pattern GameCallOfDuty :: Game
pattern GameCallOfDuty = Game "Call of Duty"

-- v0.12: optional, organizer-editable descriptive fields.
-- startTime is the scheduled start (UTC); it never starts the tournament.
data TournamentDetails = TournamentDetails
    { detailsGame      :: Maybe Game
    , detailsStartTime :: Maybe UTCTime
    , detailsPrize     :: Maybe Int
    , detailsDescription :: Maybe String
    , detailsRegistrationDeadline :: Maybe UTCTime
    , detailsEntryFee :: Maybe Int
    , detailsPlatform :: Maybe String
    , detailsRules :: Maybe String
    } deriving (Show, Eq)

noDetails :: TournamentDetails
noDetails = TournamentDetails Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing

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



-- v0.14: a tournament is either a bracket (every tournament so far) or a
-- lobby (battle royale style: placements and kills over several games).
data TournamentKind = BracketKind | LobbyKind
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
    , tournamentRegistrationDeadline :: Maybe UTCTime
    , tournamentEntryFee :: Maybe Int
    , tournamentPlatform :: Maybe String
    , tournamentRules :: Maybe String
    , tournamentKind :: TournamentKind
    } deriving (Show, Eq)

