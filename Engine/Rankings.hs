-- Engine.Rankings
-- Pure: players ranked by titles, then match wins, then name.
-- Only individual players count; squads are ignored.
module Engine.Rankings
  ( RankingEntry(..)
  , computeRankings
  ) where

import Data.List (sortBy)
import qualified Data.Map.Strict as Map
import Data.Ord (comparing, Down(..))

import Domain.Participant (Participant(..), Player(..), PlayerName(..))

data RankingEntry = RankingEntry
  { rankPlayer :: String
  , rankTitles :: Int
  , rankWins   :: Int
  } deriving (Eq, Show)

-- One fact per tournament: its champion (if decided) and the winner of every
-- completed match in it.
computeRankings :: [(Maybe Participant, [Participant])] -> [RankingEntry]
computeRankings facts = sortBy order (map toEntry (Map.toList totals))
  where
    totals = Map.fromListWith add (concatMap contributions facts)
    add (t1, w1) (t2, w2) = (t1 + t2, w1 + w2)
    contributions (champ, winners) =
      [ (n, (1 :: Int, 0 :: Int)) | Just p <- [champ], Just n <- [playerName p] ]
      ++ [ (n, (0, 1)) | p <- winners, Just n <- [playerName p] ]
    playerName (Individual (Player (PlayerName n))) = Just n
    playerName _                                    = Nothing
    toEntry (n, (t, w)) = RankingEntry n t w
    order = comparing (\e -> (Down (rankTitles e), Down (rankWins e), rankPlayer e))