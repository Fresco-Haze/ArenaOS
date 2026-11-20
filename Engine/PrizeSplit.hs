module Engine.PrizeSplit
  ( PrizeSplitError(..)
  , maxPlaces
  , validateSplit
  , splitAmounts
  ) where

data PrizeSplitError
  = SplitNoPlaces
  | SplitTooManyPlaces
  | SplitPercentTooSmall
  | SplitNotNonIncreasing
  | SplitTotalNot100
  deriving (Eq, Show)

maxPlaces :: Int
maxPlaces = 8

-- 1 to 8 places, each at least 1 percent, no place above the one before it,
-- adding up to exactly 100. Checked in that order.
validateSplit :: [Int] -> Either PrizeSplitError [Int]
validateSplit ps
  | null ps                           = Left SplitNoPlaces
  | length ps > maxPlaces             = Left SplitTooManyPlaces
  | any (< 1) ps                      = Left SplitPercentTooSmall
  | or (zipWith (<) ps (drop 1 ps))   = Left SplitNotNonIncreasing
  | sum ps /= 100                     = Left SplitTotalNot100
  | otherwise                         = Right ps

-- Whole shillings per place: the prize times the percent, rounded down. The
-- shillings left over go to first place, so the amounts add up to the prize.
splitAmounts :: Int -> [Int] -> [Int]
splitAmounts prize ps = case map (\p -> (prize * p) `div` 100) ps of
  []         -> []
  (x : rest) -> (x + (prize - sum (x : rest))) : rest