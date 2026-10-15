module Engine.Standings
  ( Standing(..)
  , MatchScores
  , computeStandings
  , computeStandingsWith
  , standingGoalDifference
  ) where

import Data.List (nub, sortBy, groupBy)
import Data.Ord (comparing, Down(..))
import Data.Function (on)

import Domain.Match (Match(..), MatchId, MatchOutcome(..))
import Domain.Participant (Participant)

data Standing = Standing
  { standingParticipant  :: Participant
  , standingPoints       :: Int
  , standingGoalsFor     :: Int
  , standingGoalsAgainst :: Int
  } deriving (Eq, Show)

standingGoalDifference :: Standing -> Int
standingGoalDifference s = standingGoalsFor s - standingGoalsAgainst s

-- | Goals per match: (goals by competitor A, goals by competitor B).
type MatchScores = [(MatchId, (Int, Int))]

pointsForOutcome :: Participant -> Match -> Int
pointsForOutcome p m = case matchOutcome m of
  Nothing                    -> 0
  Just (Winner w)            -> if w == p then 3 else 0
  Just Draw                  -> 1
  Just (Forfeit w)           -> if w == p then 3 else 0
  Just (Disqualification w)  -> if w == p then 3 else 0
  Just NoContest              -> 0

participantMatches :: Participant -> [Match] -> [Match]
participantMatches p = filter (\m -> matchCompetitorA m == p || matchCompetitorB m == p)

allParticipants :: [Match] -> [Participant]
allParticipants matches = nub (concatMap (\m -> [matchCompetitorA m, matchCompetitorB m]) matches)

totalPoints :: [Match] -> Participant -> Int
totalPoints matches p = sum (map (pointsForOutcome p) (participantMatches p matches))

-- | Standings ordered by points, then goal difference, then goals scored.
-- Players still level after all three are ordered by a single head-to-head
-- pass among that group only (the mini-league convention). A perfect cycle
-- (A beat B, B beat C, C beat A) stays unresolved. Any group still tied keeps
-- a stable but ARBITRARY order: callers must not treat that as a resolved rank.
-- Goals come only from matches that have a score and a recorded outcome;
-- matches without a score (forfeits, plain declared results) count for
-- points only.
computeStandingsWith :: MatchScores -> [Match] -> [Standing]
computeStandingsWith scores matches = concatMap resolveTiedGroup groupedByKey
  where
    ps = allParticipants matches
    standingOf p = Standing p (totalPoints matches p) (goalsFor p) (goalsAgainst p)
    goalsFor p = sum [ f | (f, _) <- goalsIn p ]
    goalsAgainst p = sum [ a | (_, a) <- goalsIn p ]
    goalsIn p =
      [ if matchCompetitorA m == p then (x, y) else (y, x)
      | m <- participantMatches p matches
      , Just _ <- [matchOutcome m]
      , Just (x, y) <- [lookup (matchId m) scores]
      ]
    key s = (standingPoints s, standingGoalDifference s, standingGoalsFor s)
    sorted = sortBy (comparing (Down . key)) (map standingOf ps)
    groupedByKey = groupBy ((==) `on` key) sorted

    resolveTiedGroup [s] = [s]
    resolveTiedGroup group =
      let members = map standingParticipant group
          miniMatches = filter (\m -> matchCompetitorA m `elem` members && matchCompetitorB m `elem` members) matches
          miniPoints p = sum (map (pointsForOutcome p) (participantMatches p miniMatches))
      in sortBy (comparing (Down . miniPoints . standingParticipant)) group

-- | Standings without goals (every goal field is 0).
computeStandings :: [Match] -> [Standing]
computeStandings = computeStandingsWith []