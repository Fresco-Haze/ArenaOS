-- Engine.Players
-- Pure: per-player totals across tournaments. A player is a name; only
-- individual players count (the caller drops squads before building facts).
module Engine.Players
  ( PlayerFact(..)
  , PlayerSummary(..)
  , summarize
  ) where

import Data.Char (toLower)
import Data.Function (on)
import Data.List (nubBy, sortBy)
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
-- Names that differ only by case are one player; the spelling used most
-- often is the one shown (the alphabetically first on a tie).
summarize :: [PlayerFact] -> [PlayerSummary]
summarize facts = sortBy order (map toSummary (Map.toList totals))
  where
    key = map toLower
    totals = Map.fromListWith add (concatMap contributions facts)
    add (e1, t1, w1) (e2, t2, w2) = (e1 + e2, t1 + t2, w1 + w2)
    contributions f =
      [ (key n, (1, 0, 0)) | n <- nubBy ((==) `on` key) (pfEntrants f) ]
      ++ [ (key n, (0, 1, 0)) | Just n <- [pfChampion f] ]
      ++ [ (key n, (0, 0, 1)) | n <- pfWinners f ]
    spellings = Map.fromListWith (Map.unionWith (+))
      [ (key n, Map.singleton n (1 :: Int))
      | f <- facts, n <- pfEntrants f ++ maybe [] pure (pfChampion f) ++ pfWinners f ]
    shown k = case Map.lookup k spellings of
      Nothing -> k
      Just m  -> case sortBy (comparing (\(n, c) -> (Down c, n))) (Map.toList m) of
        ((n, _) : _) -> n
        []           -> k
    toSummary (k, (e, t, w)) = PlayerSummary (shown k) e t w
    order = comparing (\s -> (Down (psTitles s), Down (psWins s), psName s))