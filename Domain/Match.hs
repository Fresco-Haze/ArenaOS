module Domain.Match
  ( MatchId(..)
  , MatchStatus(..)
  , MatchOutcome(..)
  , Match(..)
  ) where

import Data.Int (Int64)

import Domain.Participant (Participant)
import Domain.Tournament (TournamentId)
import Domain.Bracket (BracketId, BracketNodeId)

newtype MatchId = MatchId {unMatchId :: Int64}
    deriving (Eq, Ord, Show)

data MatchStatus
    = Scheduled
    | InProgress
    | Completed
    | Cancelled
    deriving (Eq, Show)

data MatchOutcome
    = Winner Participant
    | Draw
    | Forfeit Participant
    | Disqualification Participant
    | NoContest
    deriving (Eq, Show)

data Match = Match
    { matchId          :: MatchId
    , matchTournament  :: TournamentId
    , matchBracket     :: BracketId
    , matchBracketNode   :: BracketNodeId
    , matchCompetitorA :: Participant
    , matchCompetitorB :: Participant
    , matchStatus      :: MatchStatus
    , matchOutcome     :: Maybe MatchOutcome
    }
    deriving (Eq, Show)