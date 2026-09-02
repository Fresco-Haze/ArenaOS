module Domain.Bracket
    ( BracketId(..)
    , BracketNodeId(..)
    , BracketSide(..)
    , MatchSlot(..)
    , BracketNode(..)
    , Bracket(..)
    ) where

import Domain.Participant (Participant)
import Domain.Tournament (TournamentId)
import Domain.Ids (BracketId(..), BracketNodeId(..))




data BracketSide = Winners | Losers deriving (Show, Eq)

data MatchSlot
    = Filled Participant
    | AwaitingWinnerOf BracketNodeId
    | AwaitingLoserOf BracketNodeId
    | ByeSlot
    deriving (Show, Eq)

data BracketNode = BracketNode
    { nodeId    :: BracketNodeId
    , nodeSlotA :: MatchSlot
    , nodeSlotB :: MatchSlot
    , nodeRound :: Int
    , nodeStage :: BracketSide
    } deriving (Show, Eq)

data Bracket = Bracket
    { bracketId         :: BracketId
    , bracketTournament :: TournamentId
    , bracketGF1NodeId    :: Maybe BracketNodeId
    , bracketResetNodeId  :: Maybe BracketNodeId
    } deriving (Show, Eq)