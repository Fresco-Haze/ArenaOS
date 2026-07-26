-- Domain.Participant
-- Core domain types. No dependency on any persistence technology --
-- this module must never import Database.SQLite.Simple or anything
-- shell-side. See Architecture.md Section 13.4 / ADR-006.

module Domain.Participant
  ( PlayerName(..)
  , TeamName(..)
  , ParticipantId(..)
  , Player(..)
  , Team(..)
  , Participant(..)
  ) where

newtype PlayerName = PlayerName  String deriving (Show, Eq)
newtype TeamName = TeamName {unTeamName :: String}  deriving (Show, Eq)
newtype ParticipantId = ParticipantId {unParticipantId :: Int} deriving (Show, Eq)  -- ADR-006

data Player = Player { playerName :: PlayerName } deriving (Show, Eq)

data Team = Team
  { teamName    :: TeamName
  , teamCaptain :: Player
  , teamMembers :: [Player]
  } deriving (Show, Eq)

-- INV-8: Participants are Polymorphic
data Participant = Individual Player | Squad Team deriving (Show, Eq)