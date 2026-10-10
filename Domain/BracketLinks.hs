-- | Static downstream destinations of bracket nodes.
--
-- Derived from the bracket's pointer graph BEFORE bye resolution consumes the
-- pointers (Engine.ByeResolution replaces them with Filled slots), so the
-- relationship is a property of the bracket's structure, not of its progress.
--
-- Nothing as a destination means the generated topology has no such
-- destination. It never means "unknown": unavailable links are represented one
-- level up (a bracket with no links at all), never by a Nothing here.
module Domain.BracketLinks
    ( SlotPosition(..)
    , NodeDestination(..)
    , NodeLinks(..)
    , BracketLinks
    , lookupLinks
    ) where

import Domain.Ids (BracketNodeId)

-- | Which slot of the destination node receives the participant.
data SlotPosition = SlotA | SlotB
    deriving (Show, Eq)

data NodeDestination = NodeDestination
    { destNode :: BracketNodeId
    , destSlot :: SlotPosition
    } deriving (Show, Eq)

-- | Where the winner and the loser of a node go next.
data NodeLinks = NodeLinks
    { linkWinnerTo :: Maybe NodeDestination
    , linkLoserTo  :: Maybe NodeDestination
    } deriving (Show, Eq)

-- | One entry per node of the bracket, in the order the nodes were given.
type BracketLinks = [(BracketNodeId, NodeLinks)]

lookupLinks :: BracketNodeId -> BracketLinks -> Maybe NodeLinks
lookupLinks = lookup