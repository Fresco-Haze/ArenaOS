module Engine.BracketGeneration (bracketSize, buildTopology, buildLosersTopology,buildDoubleEliminationTopology,buildRoundRobinTopology,findParent,findSibling) where

import Domain.Bracket (BracketNode(..), BracketNodeId(..), BracketSide(..), MatchSlot(..))
import Data.List (find, partition,nub,tails)
import Data.Maybe (isJust, fromJust)
import Domain.Participant (Participant)

-- | Smallest power of two >= n. n=0 or n=1 both yield 1, but
-- validateParticipants (Engine.Validation) already rejects fewer
-- than 2 participants before this is ever called with real input.
bracketSize :: Int -> Int
bracketSize n = head (dropWhile (< n) powersOfTwo)
  where powersOfTwo = iterate (* 2) 1

-- | Builds the full bracket graph shape for a tournament of the given
-- size (already rounded up to a power of two via bracketSize).
-- Structure only -- every slot starts as ByeSlot at round 1 and
-- AwaitingWinnerOf at every later round; Engine.Seeding fills round-1
-- slots with real participants/byes afterward. This is deliberately
-- participant-count-independent: the same size always produces the
-- same shape, regardless of who's actually competing (DM-OMQ-009).
buildTopology :: Int -> [BracketNode]
buildTopology size = round1Nodes ++ go 2 round1Ids (numRound1 + 1)
  where
    numRound1 = size `div` 2
    round1Ids = [1 .. numRound1]

    round1Nodes =
      [ BracketNode (BracketNodeId i) ByeSlot ByeSlot 1 Winners | i <- round1Ids ]

    go :: Int -> [Int] -> Int -> [BracketNode]
    go _ prevIds _ | length prevIds <= 1 = []
    go rnd prevIds nextFree =
      let numThisRound = length prevIds `div` 2
          theseIds = [nextFree .. nextFree + numThisRound - 1]
          pairs = chunksOf2 prevIds
          theseNodes =
            [ BracketNode (BracketNodeId nid)
                (AwaitingWinnerOf (BracketNodeId c1))
                (AwaitingWinnerOf (BracketNodeId c2))
                rnd Winners
            | (nid, (c1, c2)) <- zip theseIds pairs ]
      in theseNodes ++ go (rnd + 1) theseIds (nextFree + numThisRound)

    chunksOf2 (a:b:rest) = (a, b) : chunksOf2 rest
    chunksOf2 _           = []

findParent :: BracketNodeId -> [BracketNode] -> Maybe BracketNodeId
findParent nid nodes =
  fmap nodeId $ find (\n -> nodeSlotA n == AwaitingWinnerOf nid
                          || nodeSlotB n == AwaitingWinnerOf nid) nodes


-- Given a WB node's id, find the round it feeds into and its sibling
-- (the other node feeding the same parent). Pure function over the
-- flat node list -- same "search, don't store" shape as
-- Engine.Advancement.propagateWinner, not a new abstraction.
findSibling :: BracketNodeId -> [BracketNode] -> Maybe BracketNodeId
findSibling nid nodes =
  case find (\n -> nodeSlotA n == AwaitingWinnerOf nid
                 || nodeSlotB n == AwaitingWinnerOf nid) nodes of
    Nothing -> Nothing  -- nid is the WB final; no parent, no sibling
    Just parent -> case (nodeSlotA parent, nodeSlotB parent) of
      (AwaitingWinnerOf a, AwaitingWinnerOf b)
        | a == nid  -> Just b
        | b == nid  -> Just a
      _ -> Nothing  -- shouldn't happen once WB is fully built

isWBByeNode :: BracketNode -> Bool
isWBByeNode n = case (nodeSlotA n, nodeSlotB n) of
  (Filled _, ByeSlot) -> True
  (ByeSlot, Filled _) -> True
  _                   -> False

realNodeOf :: (BracketNode, BracketNode) -> BracketNode
realNodeOf (a, b) = if isWBByeNode a then b else a

mkLB1Node :: Int -> BracketNode -> BracketNode -> BracketNode
-- PRECONDITION: not both a and b are WB byes -- realLB1Pairs filters
-- those out before this is ever called; a fully-byed pair produces
-- no LB1 node at all.
mkLB1Node nid a b
  | isWBByeNode a = BracketNode (BracketNodeId nid) (AwaitingLoserOf (nodeId b)) ByeSlot 1 Losers
  | isWBByeNode b = BracketNode (BracketNodeId nid) (AwaitingLoserOf (nodeId a)) ByeSlot 1 Losers
  | otherwise     = BracketNode (BracketNodeId nid) (AwaitingLoserOf (nodeId a)) (AwaitingLoserOf (nodeId b)) 1 Losers

buildLosersTopology :: [BracketNode] -> Int -> [BracketNode]
buildLosersTopology wbNodes startId = concat (lb1Nodes : go 2 initialSurvivors nextFreeAfterLB1)
  where
    wbRoundCount  = maximum (map nodeRound wbNodes)
    totalLBRounds = 2 * (wbRoundCount - 1)

    wb1Nodes = filter (\n -> nodeRound n == 1 && nodeStage n == Winners) wbNodes
    lb1Pairs = pairUp wb1Nodes
    realLB1Pairs = filter (\(a, b) -> not (isWBByeNode a && isWBByeNode b)) lb1Pairs

    lb1Nodes =
      [ mkLB1Node nid a b
      | (nid, (a, b)) <- zip [startId ..] realLB1Pairs ]
    nextFreeAfterLB1 = startId + length lb1Nodes

    initialSurvivors :: [(BracketNodeId, Maybe BracketNodeId)]
    initialSurvivors =
      [ (nodeId lbNode, findParent (nodeId (realNodeOf (a, b))) wbNodes)
      | (lbNode, (a, b)) <- zip lb1Nodes realLB1Pairs ]

    pairUp :: [BracketNode] -> [(BracketNode, BracketNode)]
    pairUp [] = []
    pairUp (n:ns) =
      case findSibling (nodeId n) wbNodes >>= \sid -> find ((== sid) . nodeId) ns of
        Just sib -> (n, sib) : pairUp (filter ((/= nodeId sib) . nodeId) ns)
        Nothing  -> pairUp ns

    go :: Int -> [(BracketNodeId, Maybe BracketNodeId)] -> Int -> [[BracketNode]]
    go lbRound _ _ | lbRound > totalLBRounds = []
    go lbRound survivors nextFree
            | even lbRound =
          let wbRound  = (lbRound `div` 2) + 1
              wbLosers = filter (\n -> nodeRound n == wbRound && nodeStage n == Winners) wbNodes
              (normalLosers, trueFinalLosers) =
                partition (\n -> isJust (findSibling (nodeId n) wbNodes)) wbLosers

              hasSurvivor loserNode =
                let sibId = findSibling (nodeId loserNode) wbNodes
                in any ((== sibId) . snd) survivors

              (matchedLosers, orphanLosers) = partition hasSurvivor normalLosers

              normalMatched =
                [ (loserNode, Just surv)
                | loserNode <- matchedLosers
                , let sibId = findSibling (nodeId loserNode) wbNodes
                , surv <- take 1 (filter ((== sibId) . snd) survivors) ]

              usedIds  = [ sid | (_, Just (sid, _)) <- normalMatched ]
              leftover = filter (\(sid, _) -> sid `notElem` usedIds) survivors
              finalMatched = [ (loserNode, Just surv) | (loserNode, surv) <- zip trueFinalLosers leftover ]

              -- A WB loser whose tagged cross-seed sibling produced no
              -- surviving LB lineage (its whole WB1 family was byes) has
              -- no legitimate cross-seed partner. Same (Filled, ByeSlot)
              -- trick as everywhere else -- not a silent drop.
              orphanMatched = [ (loserNode, Nothing) | loserNode <- orphanLosers ]

              matched = normalMatched ++ finalMatched ++ orphanMatched

              theseNodes =
                [ BracketNode (BracketNodeId nid)
                    (AwaitingLoserOf (nodeId loserNode))
                    (maybe ByeSlot (AwaitingWinnerOf . fst) mSurv)
                    lbRound Losers
                | (nid, (loserNode, mSurv)) <- zip [nextFree ..] matched ]
              newTags =
                [ (nodeId n, findParent (nodeId loserNode) wbNodes)
                | (n, (loserNode, _)) <- zip theseNodes matched ]
          in theseNodes : go (lbRound + 1) newTags (nextFree + length theseNodes)

            | otherwise =
                let groups = groupByTag survivors
                    pairs  = [ (tag, a, b) | (tag, [(a, _), (b, _)]) <- groups ]
                    theseNodes = [ BracketNode (BracketNodeId nid) (AwaitingWinnerOf a) (AwaitingWinnerOf b) lbRound Losers
                                 | (nid, (_, a, b)) <- zip [nextFree ..] pairs ]
                    newTags = [ (nodeId n, tag) | (n, (tag, _, _)) <- zip theseNodes pairs ]
                in theseNodes : go (lbRound + 1) newTags (nextFree + length theseNodes)

    groupByTag survivors = [ (t, filter ((== t) . snd) survivors) | t <- nub (map snd survivors) ]


buildDoubleEliminationTopology :: [BracketNode] -> Int -> ([BracketNode], BracketNodeId, BracketNodeId)
-- wbNodes must already be seeded (Engine.Seeding.seedParticipants) before this is called --
-- buildLosersTopology needs real bye/match slots to build LB1 correctly.
-- returns (otherNodes [LB ++ GF1 ++ reset], gf1Id, resetId)
buildDoubleEliminationTopology wbNodes size =
  let wbFinalId = nodeId $ head $ filter (\n -> nodeRound n == maximum (map nodeRound wbNodes)) wbNodes
      lbNodes   = buildLosersTopology wbNodes size
      lbFinalId = nodeId (last lbNodes)
      wbRoundCount = maximum (map nodeRound wbNodes)
      gf1Id   = BracketNodeId (size + length lbNodes)
      gf1Node = BracketNode gf1Id (AwaitingWinnerOf wbFinalId) (AwaitingWinnerOf lbFinalId) (wbRoundCount + 1) Winners
      resetId   = BracketNodeId (unBracketNodeId gf1Id + 1)
      resetNode = BracketNode resetId (AwaitingWinnerOf gf1Id) (AwaitingLoserOf gf1Id) (wbRoundCount + 2) Winners
  in (lbNodes ++ [gf1Node, resetNode], gf1Id, resetId)


buildRoundRobinTopology :: [Participant] -> [BracketNode]
buildRoundRobinTopology ps =
  [ BracketNode (BracketNodeId i) (Filled a) (Filled b) 1 Winners
  | (i, (a, b)) <- zip [1 ..] (pairUp ps) ]
  where
    pairUp xs = [ (a, b) | (a:rest) <- tails xs, b <- rest ]
                                 