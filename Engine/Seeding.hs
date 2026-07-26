module Engine.Seeding (seedParticipants) where

import Domain.Bracket (BracketNode(..), MatchSlot(..))
import Domain.Participant (Participant)

-- | Assigns participants into the round-1 slots of an already-built
-- bracket graph. Byes are given to however many participants don't
-- have an opponent (numByes = numRound1Nodes*2 - length ps); the
-- remaining participants pair up into real first-round matches.
--
-- Safety note: numByes is guaranteed non-negative and strictly less
-- than numRound1Nodes by construction (DM-OMQ-010's proof — nodes
-- here comes from a bracket built via bracketSize/buildTopology
-- against this same participant list, so every bye has its own
-- round-1 node to occupy). This function is intentionally partial
-- with respect to that invariant, same as the original hand-verified
-- pipeline — it is not exposed as a public entry point on
-- mismatched inputs; only Engine.BracketGeneration's own pipeline
-- calls it with nodes it just built.
seedParticipants :: [Participant] -> [BracketNode] -> [BracketNode]
seedParticipants ps nodes = map applySeed nodes
  where
    round1 = filter ((== 1) . nodeRound) nodes
    numRound1 = length round1
    numByes = numRound1 * 2 - length ps

    (byeParticipants, matchParticipants) = splitAt numByes ps

    byeSlotPairs = [ (Filled p, ByeSlot) | p <- byeParticipants ]
    matchSlotPairs = pairUp matchParticipants

    pairUp (a:b:rest) = (Filled a, Filled b) : pairUp rest
    pairUp _           = []

    assignment = zip (map nodeId round1) (byeSlotPairs ++ matchSlotPairs)

    applySeed n = case lookup (nodeId n) assignment of
        Just (a, b) -> n { nodeSlotA = a, nodeSlotB = b }
        Nothing     -> n