module Domain.Prediction
  ( Pick(..)
  ) where

-- | A user's guess for one match: competitor A wins, B wins, or a draw.
data Pick = PickA | PickB | PickDraw
  deriving (Eq, Show)
