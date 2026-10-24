-- Engine.Champion
-- Pure: who won a tournament, read off its bracket and matches.
-- Moved out of CompleteTournament so rankings can reuse the same rules.
module Engine.Champion
  ( championOutcome
  , lookupMatchForNode
  , findChampionMatch
  , findChampionMatchDoubleElim
  , matchOutcomeWinner
  , tournamentChampion
  ) where

import Data.List (find, maximumBy)
import Data.Ord (comparing)

import Domain.Bracket (Bracket(..), BracketNode(..), BracketNodeId, MatchSlot(..))
import Domain.Match (Match(..), MatchStatus(..), MatchOutcome(..))
import Domain.Participant (Participant)
import Domain.Tournament (TournamentFormat(..))

-- The champion of a finished bracket tournament. Round robin has no single
-- champion here: a tie at the top of the table is not resolved by Standings.
tournamentChampion :: TournamentFormat -> Bracket -> [BracketNode] -> [Match] -> Maybe Participant
tournamentChampion RoundRobin _ _ _ = Nothing
tournamentChampion _ bracket nodes matches =
  case (bracketGF1NodeId bracket, bracketResetNodeId bracket) of
    (Just gf1Id, Just resetId) ->
      findChampionMatchDoubleElim gf1Id (Just resetId) nodes matches >>= matchOutcomeWinner
    _ ->
      findChampionMatch (bracketThirdPlaceNodeId bracket) nodes matches >>= matchOutcomeWinner

findChampionMatchDoubleElim
  :: BracketNodeId -> Maybe BracketNodeId -> [BracketNode] -> [Match] -> Maybe Match
findChampionMatchDoubleElim gf1Id mResetId nodes matches = do
  gf1Node  <- find ((== gf1Id) . nodeId) nodes
  gf1Match <- lookupMatchForNode gf1Id matches >>= championOutcome
  winner   <- matchOutcomeWinner gf1Match
  case nodeSlotB gf1Node of
    Filled lbChampion
      | winner == lbChampion ->
          mResetId >>= \rid -> lookupMatchForNode rid matches >>= championOutcome
      | otherwise -> Just gf1Match
    _ -> Nothing

matchOutcomeWinner :: Match -> Maybe Participant
matchOutcomeWinner m = case matchOutcome m of
  Just (Winner p)           -> Just p
  Just (Forfeit p)          -> Just p
  Just (Disqualification p) -> Just p
  _                         -> Nothing

-- The final node (highest round, third-place node excluded) must have a
-- Completed match whose outcome names an advancing participant.
findChampionMatch :: Maybe BracketNodeId -> [BracketNode] -> [Match] -> Maybe Match
findChampionMatch mThirdPlaceId nodes matches
  | null candidates = Nothing
  | otherwise = do
      let finalNode = maximumBy (comparing nodeRound) candidates
      m <- lookupMatchForNode (nodeId finalNode) matches
      championOutcome m
  where
    candidates = filter (\n -> Just (nodeId n) /= mThirdPlaceId) nodes

lookupMatchForNode :: BracketNodeId -> [Match] -> Maybe Match
lookupMatchForNode nid = find (\m -> matchBracketNode m == nid)

championOutcome :: Match -> Maybe Match
championOutcome m = case (matchStatus m, matchOutcome m) of
  (Completed, Just (Winner _))           -> Just m
  (Completed, Just (Forfeit _))          -> Just m
  (Completed, Just (Disqualification _)) -> Just m
  _                                      -> Nothing