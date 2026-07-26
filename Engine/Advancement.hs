module Engine.Advancement (propagateWinner, advanceBracket, completeMatch) where

import Domain.Bracket (BracketNode(..), BracketNodeId, MatchSlot(..))
import Domain.Match (Match(..), MatchOutcome, MatchStatus(..))
import Domain.Participant (Participant)

propagateWinner :: BracketNodeId -> Participant -> [BracketNode] -> [BracketNode]
propagateWinner sourceId winner = map fillAwaiting
  where
    fillAwaiting n
      | nodeSlotA n == AwaitingWinnerOf sourceId = n { nodeSlotA = Filled winner }
      | nodeSlotB n == AwaitingWinnerOf sourceId = n { nodeSlotB = Filled winner }
      | otherwise = n

-- | Advances a bracket graph after a match's winner becomes official.
-- Identical to propagateWinner -- bye-resolution and post-match
-- advancement are the same graph transformation, just triggered by
-- different events (initial graph shape vs. a reported
-- MatchOutcome). Kept as a distinct name because callers reason
-- about them differently: Engine.ByeResolution calls this
-- automatically during bracket generation, while a future
-- ReportMatchResult use case will call it after an organizer submits
-- an official result.
advanceBracket :: BracketNodeId -> Participant -> [BracketNode] -> [BracketNode]
advanceBracket = propagateWinner

completeMatch :: MatchOutcome -> Match -> Match
completeMatch outcome m = m { matchStatus = Completed, matchOutcome = Just outcome }