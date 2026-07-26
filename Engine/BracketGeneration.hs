module Engine.BracketGeneration (bracketSize, buildTopology) where

import Domain.Bracket (BracketNode(..), BracketNodeId(..), BracketSide(..), MatchSlot(..))

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