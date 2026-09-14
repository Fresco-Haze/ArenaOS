module Engine.Correction.DoubleEliminationLineage
  ( resolveWBWinnerTarget
  , resolveWBLoserTarget
  , resolveLBTarget
  , GF1Outcome(..)
  , classifyGF1Outcome
  , LineageError(..)
  ) where

import Data.List (find)

import Domain.Bracket (BracketNode(..), BracketNodeId, MatchSlot(..))
import Domain.Participant (Participant)
import Engine.BracketGeneration (buildTopology, buildLosersTopology, findParent)

-- | Failures specific to pure lineage resolution. Kept local to this
-- module rather than folded into CorrectMatchResultError, since this
-- layer has no access to (and shouldn't know about) the Application
-- layer's error type. The boundary between this and
-- CorrectMatchResultError is decided at the call site in
-- correctMatchResultInTx, not here.
data LineageError
  = NoLoserTarget BracketNodeId
    -- ^ Not a corruption signal. A legitimate structural result: the
    -- given WB node was a bye (per Engine.Seeding), so it never
    -- produced a loser and therefore has no Losers Bracket edge.
    -- Confirmed via a real n=6/size=8 trace against
    -- Engine.BracketGeneration.buildLosersTopology and
    -- Engine.Seeding.seedParticipants.
  deriving (Eq, Show)

-- | The WB-internal winner target of a WB source match. Nothing iff
-- the source is the WB Final (no WB-internal parent -- its winner
-- goes to GF1 instead, read from Bracket.bracketGF1NodeId at the
-- call site, not resolved here).
--
-- Pure over size alone: buildTopology's own recursive shape never
-- touches bye/fill content (round 1 is always (ByeSlot, ByeSlot) at
-- construction; every later round is always AwaitingWinnerOf,
-- unconditionally), so no live/persisted node list is needed here,
-- unlike the two functions below.
resolveWBWinnerTarget :: Int -> BracketNodeId -> Maybe BracketNodeId
resolveWBWinnerTarget size sourceId = findParent sourceId (buildTopology size)

-- | The Losers Bracket destination of a WB source match's loser.
--
-- Right target = this WB node actually produced a loser (a real
--   match was played there).
-- Left NoLoserTarget = this WB node was a bye and therefore never
--   produced a loser at all -- no LB edge exists for it, by
--   construction, not by error.
--
-- PRECONDITIONS the caller must satisfy:
--   * wbNodes must be the bracket's REAL persisted WB nodes
--     (nodeStage == Winners, from Repo.getBracket) -- the bye
--     pattern determined by Engine.Seeding directly changes which
--     LB nodes exist and how they're wired (buildLosersTopology's
--     isWBByeNode/orphanLosers branches), so a freshly-reseeded or
--     hypothetical node list will not necessarily match what's
--     actually persisted.
--   * startId must equal the same `size` value passed to
--     buildDoubleEliminationTopology at generation time (confirmed
--     via Engine/BracketGeneration.hs: the only call site does
--     `buildLosersTopology wbNodes size`). At correction time this
--     should be derived from persisted nodes exactly as
--     Application.UseCases.CorrectMatchResult already does for SE:
--     `length (filter (\n -> nodeRound n == 1 && nodeStage n == Winners) nodes) * 2`
--     -- note the DE version must filter to nodeStage == Winners,
--     unlike the existing SE line, since DE's node list also
--     contains Losers-stage round-1 nodes (LB1).
resolveWBLoserTarget
  :: [BracketNode] -> Int -> BracketNodeId -> Either LineageError BracketNodeId
resolveWBLoserTarget wbNodes startId sourceId =
  let lbNodes = buildLosersTopology wbNodes startId
      matchesSource n = nodeSlotA n == AwaitingLoserOf sourceId
                      || nodeSlotB n == AwaitingLoserOf sourceId
  in case find matchesSource lbNodes of
       Just n  -> Right (nodeId n)
       Nothing -> Left (NoLoserTarget sourceId)

-- | The LB-internal winner target of an LB source match. Nothing iff
-- the source is the LB Final (its winner target is GF1, not another
-- LB node -- read Bracket.bracketGF1NodeId at the call site).
--
-- Same preconditions as resolveWBLoserTarget re: wbNodes and startId.
resolveLBTarget :: [BracketNode] -> Int -> BracketNodeId -> Maybe BracketNodeId
resolveLBTarget wbNodes startId sourceId =
  let lbNodes = buildLosersTopology wbNodes startId
      matchesSource n = nodeSlotA n == AwaitingWinnerOf sourceId
                      || nodeSlotB n == AwaitingWinnerOf sourceId
  in nodeId <$> find matchesSource lbNodes

-- | Whether GF1's winner is the zero-loss player (Decisive -- the
-- tournament is over) or the one-loss player (ResetRequired -- a
-- reset match is needed). Classified by VALUE (compare the GF1
-- winner against the WB Final's winner), not by structural slot --
-- consistent with dropping the Slot type from correction entirely.
-- Relies on DI-11 (a match's two competitors are always distinct)
-- for this equality check to be unambiguous.
data GF1Outcome = Decisive | ResetRequired deriving (Eq, Show)

classifyGF1Outcome
  :: Participant  -- ^ the WB Final's winner (entered GF1 with zero losses)
  -> Participant  -- ^ GF1's winner, old or new, whichever is being classified
  -> GF1Outcome
classifyGF1Outcome wbFinalWinner gf1Winner
  | gf1Winner == wbFinalWinner = Decisive
  | otherwise                  = ResetRequired