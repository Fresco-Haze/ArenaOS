module Engine.ByeResolution (resolveAutomaticAdvancements) where

import Domain.Bracket (BracketNode(..), MatchSlot(..))
import Engine.Advancement (propagateWinner)

-- | Finds every node representing a bye (one real participant, one
-- ByeSlot -- never a Match, per DM-OMQ-008) and propagates that
-- participant forward as if they'd won. Two bye recipients can
-- legitimately land against each other in round 2, playable before
-- round 1 elsewhere finishes -- correct behavior, falls out for
-- free from Engine.Materialization's readyNodes check.
resolveAutomaticAdvancements :: [BracketNode] -> [BracketNode]
resolveAutomaticAdvancements nodes = foldl propagate nodes byeNodes
  where
    byeNodes = [ n | n <- nodes, isByeNode n ]

    isByeNode n = case (nodeSlotA n, nodeSlotB n) of
        (Filled _, ByeSlot) -> True
        (ByeSlot, Filled _) -> True
        _                   -> False

    byeWinner n = case (nodeSlotA n, nodeSlotB n) of
        (Filled p, ByeSlot) -> Just p
        (ByeSlot, Filled p) -> Just p
        _                   -> Nothing

    propagate ns byeNode = case byeWinner byeNode of
        Just winner -> propagateWinner (nodeId byeNode) winner ns
        Nothing     -> ns