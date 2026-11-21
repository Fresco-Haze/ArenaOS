-- Domain.Series
-- One game inside a best-of series. Pure data only.
module Domain.Series
    ( MatchGame(..)
    ) where

import Domain.Ids (UserId)

data MatchGame = MatchGame
    { gameNo         :: Int
    , gameScoreA     :: Int
    , gameScoreB     :: Int
    , gameConfirmed  :: Bool
    , gameReportedBy :: UserId
    } deriving (Show, Eq)