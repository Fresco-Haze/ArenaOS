module Engine.Standings (Standing(..), computeStandings) where

import Data.List (nub, sortBy, groupBy)
import Data.Ord (comparing, Down(..))
import Data.Function (on)

import Domain.Match (Match(..), MatchOutcome(..))
import Domain.Participant (Participant)

data Standing = Standing
  { standingParticipant :: Participant
  , standingPoints      :: Int
  } deriving (Eq, Show)

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

-- | Standings sorted by points descending; ties broken by a single
-- head-to-head pass restricted to matches played only among the tied
-- group (the "mini-league" convention -- confirmed the dominant
-- approach across independent sources: USAU, MTG tournament rules,
-- Toornament). A perfect-cycle tie (A beat B, B beat C, C beat A)
-- produces an equal mini-league record for all three and is NOT
-- resolved further -- deeper tiers (score/goal differential,
-- iterative re-narrowing on a partial sub-tie) are explicitly
-- deferred, same posture as the points table's own deferred tiers.
-- Any group still tied after the mini-league pass keeps a stable but
-- ARBITRARY order -- callers must not treat that as a resolved rank.
computeStandings :: [Match] -> [Standing]
computeStandings matches = concatMap resolveTiedGroup groupedByPoints
  where
    ps = allParticipants matches
    byPointsDesc = sortBy (comparing (Down . totalPoints matches)) ps
    groupedByPoints = groupBy ((==) `on` totalPoints matches) byPointsDesc

    resolveTiedGroup :: [Participant] -> [Standing]
    resolveTiedGroup [p] = [Standing p (totalPoints matches p)]
    resolveTiedGroup group =
      let miniMatches = filter (\m -> matchCompetitorA m `elem` group && matchCompetitorB m `elem` group) matches
          miniPoints p = sum (map (pointsForOutcome p) (participantMatches p miniMatches))
          ordered = sortBy (comparing (Down . miniPoints)) group
      in [ Standing p (totalPoints matches p) | p <- ordered ]