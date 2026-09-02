module Domain.Scoreable
  ( ScoreComparison(..)
  , Scoreable(..)
  , EFootballScore
  , mkEFootballScore
  , ScoreError(..)
  , unEFootballScore
  
  ) where

data ScoreComparison = FirstWins | SecondWins | Tied
  deriving (Show, Eq)

class Scoreable a where
  compareScores :: a -> a -> ScoreComparison

-- | Goal count for one competitor in an eFootball match.
newtype EFootballScore = EFootballScore Int
  deriving (Show, Eq)

data ScoreError = NegativeScore Int
  deriving (Show, Eq)

mkEFootballScore :: Int -> Either ScoreError EFootballScore
mkEFootballScore n

  | n < 0     = Left (NegativeScore n)
  | otherwise = Right (EFootballScore n)

unEFootballScore :: EFootballScore -> Int
unEFootballScore (EFootballScore n) = n

instance Scoreable EFootballScore where
  compareScores (EFootballScore a) (EFootballScore b)
    | a > b     = FirstWins
    | a < b     = SecondWins
    | otherwise = Tied