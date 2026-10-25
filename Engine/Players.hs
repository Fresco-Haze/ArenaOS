-- Engine.Players
-- Pure: per-player totals across tournaments. A player is a name; only
-- individual players count (the caller drops squads before building facts).
module Engine.Players
  ( PlayerFact(..)
  , PlayerSummary(..)
  , summarize
  ) where

import Data.List (nub, sortBy)
import qualified Data.Map.Strict as Map
import Data.Ord (comparing, Down(..))

-- One fact per tournament: who entered, who won it (if decided), and the
-- winner of every completed match in it.
data PlayerFact = PlayerFact
  { pfEntrants :: [String]
  , pfChampion :: Maybe String
  , pfWinners  :: [String]
  } deriving (Eq, Show)

data PlayerSummary = PlayerSummary
  { psName    :: String
  , psEntered :: Int
  , psTitles  :: Int
  , psWins    :: Int
  } deriving (Eq, Show)

-- Ordered by titles, then wins, then name (same order as the rankings).
summarize :: [PlayerFact] -> [PlayerSummary]
summarize facts = sortBy order (map toSummary (Map.toList totals))
  where
    totals = Map.fromListWith add (concatMap contributions facts)
    add (e1, t1, w1) (e2, t2, w2) = (e1 + e2, t1 + t2, w1 + w2)
    contributions f =
      [ (n, (1, 0, 0)) | n <- nub (pfEntrants f) ]
      ++ [ (n, (0, 1, 0)) | Just n <- [pfChampion f] ]
      ++ [ (n, (0, 0, 1)) | n <- pfWinners f ]
    toSummary (n, (e, t, w)) = PlayerSummary n e t w
    order = comparing (\s -> (Down (psTitles s), Down (psWins s), psName s))