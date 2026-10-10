-- | Pure derivation of winner/loser destinations from a bracket's pointers.
--
-- The input must be the graph as generated, BEFORE bye resolution: once an
-- AwaitingWinnerOf / AwaitingLoserOf pointer has been replaced by a Filled
-- slot, the link it carried is gone from the node list and cannot be derived.
module Engine.BracketLinks
    ( LinkError(..)
    , deriveLinks
    ) where

import Domain.Bracket (BracketNode(..), MatchSlot(..))
import Domain.BracketLinks
    ( BracketLinks
    , NodeDestination(..)
    , NodeLinks(..)
    , SlotPosition(..)
    )
import Domain.Ids (BracketNodeId)

data LinkError
    = DuplicateNodeId BracketNodeId
      -- ^ two nodes share an id
    | DanglingPointer BracketNodeId BracketNodeId
      -- ^ holder of the pointer, and the node id it points at that is not in the graph
    | ConflictingWinnerDestination BracketNodeId NodeDestination NodeDestination
      -- ^ one node's winner is claimed by two different slots
    | ConflictingLoserDestination BracketNodeId NodeDestination NodeDestination
      -- ^ one node's loser is claimed by two different slots
    deriving (Show, Eq)

data EdgeKind = WinnerEdge | LoserEdge
    deriving (Eq)

-- | kind of pointer, the node it points at (the source), and the slot holding it
data Edge = Edge EdgeKind BracketNodeId NodeDestination

-- | Total over its input: every node gets exactly one entry, in input order.
-- Winner and loser destinations are independent; each outcome of each node
-- must have at most one destination.
deriveLinks :: [BracketNode] -> Either LinkError BracketLinks
deriveLinks nodes =
    case duplicateIds of
        d : _ -> Left (DuplicateNodeId d)
        [] ->
            case danglingEdges of
                Edge _ missing dest : _ -> Left (DanglingPointer (destNode dest) missing)
                [] -> traverse linksFor nodes
  where
    ids = map nodeId nodes

    duplicateIds = [ i | (k, i) <- zip [0 :: Int ..] ids, i `elem` take k ids ]

    edges =
        [ Edge kind src (NodeDestination (nodeId n) pos)
        | n <- nodes
        , (pos, slot) <- [(SlotA, nodeSlotA n), (SlotB, nodeSlotB n)]
        , Just (kind, src) <- [pointerOf slot]
        ]

    danglingEdges = [ e | e@(Edge _ src _) <- edges, src `notElem` ids ]

    linksFor n = do
        w <- single n WinnerEdge ConflictingWinnerDestination
        l <- single n LoserEdge ConflictingLoserDestination
        pure (nodeId n, NodeLinks w l)

    single n kind conflict =
        case [ d | Edge k src d <- edges, k == kind, src == nodeId n ] of
            []          -> Right Nothing
            [d]         -> Right (Just d)
            (a : b : _) -> Left (conflict (nodeId n) a b)

pointerOf :: MatchSlot -> Maybe (EdgeKind, BracketNodeId)
pointerOf (AwaitingWinnerOf s) = Just (WinnerEdge, s)
pointerOf (AwaitingLoserOf s)  = Just (LoserEdge, s)
pointerOf _                    = Nothing