module Engine.Predictions
  ( Pick(..)
  , PredictionResult(..)
  , LeaderboardRow(..)
  , predictionOpen
  , pickAllowed
  , scorePrediction
  , buildLeaderboard
  , leaderboardPoints
  ) where

import Data.Function (on)
import Data.List (groupBy, sortBy)
import Data.Ord (comparing, Down(..))

import Domain.Ids (UserId(..))
import Domain.Prediction (Pick(..))
import Domain.Match (Match(..), MatchOutcome(..), MatchStatus(..))
import Domain.Tournament (TournamentFormat(..))

-- | How one pick turned out. Void = no contest, cancelled, or an outcome that
-- names someone who is not in the match. Pending = the match is not finished.
data PredictionResult = Correct | Wrong | Void | Pending
  deriving (Eq, Show)

-- | Picks can only be saved or changed while the match is still Scheduled.
predictionOpen :: Match -> Bool
predictionOpen m = matchStatus m == Scheduled

-- | A draw can only be picked in round robin; elsewhere every match has a winner.
pickAllowed :: TournamentFormat -> Pick -> Bool
pickAllowed _ PickA = True
pickAllowed _ PickB = True
pickAllowed fmt PickDraw = fmt == RoundRobin

-- | Winner, forfeit and disqualification all name the participant who advances,
-- so a pick for that side is correct.
scorePrediction :: Match -> Pick -> PredictionResult
scorePrediction m pick =
  case matchStatus m of
    Cancelled -> Void
    Completed -> settle (matchOutcome m)
    _         -> Pending
  where
    settle (Just (Winner p))           = side p
    settle (Just (Forfeit p))          = side p
    settle (Just (Disqualification p)) = side p
    settle (Just Draw)                 = if pick == PickDraw then Correct else Wrong
    settle (Just NoContest)            = Void
    settle Nothing                     = Pending
    side p
      | p == matchCompetitorA m = if pick == PickA then Correct else Wrong
      | p == matchCompetitorB m = if pick == PickB then Correct else Wrong
      | otherwise               = Void

data LeaderboardRow = LeaderboardRow
  { lbUser    :: UserId
  , lbCorrect :: Int
  , lbWrong   :: Int
  } deriving (Eq, Show)

-- | One point per correct pick.
leaderboardPoints :: LeaderboardRow -> Int
leaderboardPoints = lbCorrect

-- | Void and pending picks do not count. Most correct first, then fewest wrong,
-- then lowest user id so the order is stable.
buildLeaderboard :: [(UserId, PredictionResult)] -> [LeaderboardRow]
buildLeaderboard entries = sortBy order rows
  where
    order = comparing (Down . lbCorrect) <> comparing lbWrong <> comparing (unUserId . lbUser)
    settled = [ e | e@(_, r) <- entries, r == Correct || r == Wrong ]
    byUser = groupBy ((==) `on` (unUserId . fst)) (sortBy (comparing (unUserId . fst)) settled)
    rows = [ LeaderboardRow u (length [ () | (_, Correct) <- g ]) (length [ () | (_, Wrong) <- g ])
           | g@((u, _) : _) <- byUser ]
