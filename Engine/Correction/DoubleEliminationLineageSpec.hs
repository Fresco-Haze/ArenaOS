module Engine.Correction.DoubleEliminationLineageSpec (spec) where

import Test.Hspec

import Domain.Bracket (BracketNode(..), BracketNodeId(..), BracketSide(..), MatchSlot(..))
import Domain.Participant (Participant(..))  -- adjust import if Participant's real constructor/fields differ
import Engine.BracketGeneration (bracketSize, buildTopology)
import Engine.Seeding (seedParticipants)
import Engine.Correction.DoubleEliminationLineage
  ( resolveWBWinnerTarget
  , resolveWBLoserTarget
  , resolveLBTarget
  , LineageError(..)
  )

spec :: Spec
spec = do
  resolveWBWinnerTargetSpec
  resolveWBLoserTargetSpec
  resolveLBTargetSpec

-- | Fixture participants. Adjust the Participant construction to
-- match its real definition -- this assumes a simple wrapper; if
-- Participant carries more fields (e.g. a name plus an id), this
-- needs the real constructor instead.
mkParticipants :: Int -> [Participant]
mkParticipants n = [ Participant i | i <- [1 .. n] ]

-- | Real production construction path, not hand-typed node literals
-- -- built the same way Engine.BracketGeneration's own pipeline
-- builds it, so the fixture can't silently diverge from what's
-- actually generated.
wbNodesFor :: Int -> [BracketNode]
wbNodesFor n =
  filter ((== Winners) . nodeStage) (seedParticipants (mkParticipants n) (buildTopology (bracketSize n)))

wb4, wb8, wb6 :: [BracketNode]
wb4 = wbNodesFor 4
wb8 = wbNodesFor 8
wb6 = wbNodesFor 6  -- size=8, 2 byes -- the bye-dependent case

resolveWBWinnerTargetSpec :: Spec
resolveWBWinnerTargetSpec = describe "resolveWBWinnerTarget" $ do
  context "n=4" $ do
    it "WB R1 node1 targets the WB Final (node3)" $
      resolveWBWinnerTarget 4 1 `shouldBe` Just 3
    it "WB R1 node2 targets the WB Final (node3)" $
      resolveWBWinnerTarget 4 2 `shouldBe` Just 3
    it "the WB Final (node3) has no WB-internal target" $
      resolveWBWinnerTarget 4 3 `shouldBe` Nothing

  context "n=8" $ do
    it "WB R1 node1 targets R2 node5" $
      resolveWBWinnerTarget 8 1 `shouldBe` Just 5
    it "WB R1 node3 targets R2 node6" $
      resolveWBWinnerTarget 8 3 `shouldBe` Just 6
    it "R2 node5 targets the WB Final (node7)" $
      resolveWBWinnerTarget 8 5 `shouldBe` Just 7
    it "the WB Final (node7) has no WB-internal target" $
      resolveWBWinnerTarget 8 7 `shouldBe` Nothing

resolveWBLoserTargetSpec :: Spec
resolveWBLoserTargetSpec = describe "resolveWBLoserTarget" $ do
  context "n=4" $ do
    it "WB R1 node1 -> LB1 (node4)" $ resolveWBLoserTarget wb4 4 1 `shouldBe` Right 4
    it "WB R1 node2 -> LB1 (node4)" $ resolveWBLoserTarget wb4 4 2 `shouldBe` Right 4
    it "WB Final node3 -> LB Final (node5)" $ resolveWBLoserTarget wb4 4 3 `shouldBe` Right 5

  context "n=8, no byes" $ do
    it "WB1 node1 -> LB1a (node8)" $ resolveWBLoserTarget wb8 8 1 `shouldBe` Right 8
    it "WB1 node2 -> LB1a (node8)" $ resolveWBLoserTarget wb8 8 2 `shouldBe` Right 8
    it "WB1 node3 -> LB1b (node9)" $ resolveWBLoserTarget wb8 8 3 `shouldBe` Right 9
    it "WB1 node4 -> LB1b (node9)" $ resolveWBLoserTarget wb8 8 4 `shouldBe` Right 9
    it "WB2 node5 -> LB2a (node10)" $ resolveWBLoserTarget wb8 8 5 `shouldBe` Right 10
    it "WB2 node6 -> LB2b (node11)" $ resolveWBLoserTarget wb8 8 6 `shouldBe` Right 11
    it "WB Final node7 -> LB Final (node13)" $ resolveWBLoserTarget wb8 8 7 `shouldBe` Right 13

  context "n=6, size=8, with byes (node1/node2 are byes)" $ do
    it "bye node1 has no loser target" $
      resolveWBLoserTarget wb6 8 1 `shouldBe` Left (NoLoserTarget 1)
    it "bye node2 has no loser target" $
      resolveWBLoserTarget wb6 8 2 `shouldBe` Left (NoLoserTarget 2)
    it "real-match node3 -> LB1 (node8)" $
      resolveWBLoserTarget wb6 8 3 `shouldBe` Right 8
    it "real-match node4 -> LB1 (node8)" $
      resolveWBLoserTarget wb6 8 4 `shouldBe` Right 8
    it "WB2 node5 -> node9" $
      resolveWBLoserTarget wb6 8 5 `shouldBe` Right 9
    it "WB2 node6 -> node10 (the orphan-fed LB node)" $
      resolveWBLoserTarget wb6 8 6 `shouldBe` Right 10
    it "WB Final node7 -> LB Final (node12)" $
      resolveWBLoserTarget wb6 8 7 `shouldBe` Right 12

resolveLBTargetSpec :: Spec
resolveLBTargetSpec = describe "resolveLBTarget" $ do
  context "n=4" $
    it "LB1 (node4) -> LB Final (node5)" $ resolveLBTarget wb4 4 4 `shouldBe` Just 5

  context "n=8, no byes" $ do
    it "LB1a (node8) -> LB2b (node11), cross-seeded" $
      resolveLBTarget wb8 8 8 `shouldBe` Just 11
    it "LB1b (node9) -> LB2a (node10), cross-seeded" $
      resolveLBTarget wb8 8 9 `shouldBe` Just 10
    it "LB2a (node10) -> LB3 (node12)" $
      resolveLBTarget wb8 8 10 `shouldBe` Just 12
    it "LB2b (node11) -> LB3 (node12)" $
      resolveLBTarget wb8 8 11 `shouldBe` Just 12
    it "LB3 (node12) -> LB Final (node13)" $
      resolveLBTarget wb8 8 12 `shouldBe` Just 13
    it "LB Final (node13) has no LB-internal target" $
      resolveLBTarget wb8 8 13 `shouldBe` Nothing

  context "n=6, size=8, with byes" $ do
    it "LB1 (node8) -> node9" $
      resolveLBTarget wb6 8 8 `shouldBe` Just 9
    it "the orphan/bye-shaped node10 still has a normal winner target" $
      resolveLBTarget wb6 8 10 `shouldBe` Just 11
    it "node9 -> node11" $
      resolveLBTarget wb6 8 9 `shouldBe` Just 11
    it "node11 -> LB Final (node12)" $
      resolveLBTarget wb6 8 11 `shouldBe` Just 12
    it "LB Final (node12) has no LB-internal target" $
      resolveLBTarget wb6 8 12 `shouldBe` Nothing