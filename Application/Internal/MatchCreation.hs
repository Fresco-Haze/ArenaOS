-- | Shared match-creation logic for the two places a ready BracketNode
-- gets turned into a persisted Match row: GenerateBracket (initial
-- materialization, batched across every ready node in a fresh bracket)
-- and RecordMatchResult (incremental materialization, one node at a time
-- as results unlock downstream nodes). Both need identical
-- resolve-participants -> create-match plumbing; only how they obtain the
-- node's real storage id, and what happens after the Match row exists,
-- differ -- so only that shared plumbing lives here.
module Application.Internal.MatchCreation
  ( createMatchForReadyNode
  ) where

import Control.Exception (assert)

import Domain.Bracket (BracketId, BracketNode(..), BracketNodeId, MatchSlot(..))
import Domain.Match (MatchId)
import Domain.Tournament (TournamentId)

import Shell.Persistence.Port
  ( MatchRepository
  , ParticipantRepository
  , NewMatch(..)
  )
import qualified Shell.Persistence.Port as Repo

-- | Resolves a ready node's two competitors to ParticipantIds and mints a
-- MatchId for it via MatchRepository.createMatch. The caller supplies the
-- node's real (persisted) storage id directly -- DI-12: the persisted
-- Match retains a deterministic link back to its originating BracketNode
-- -- since the two call sites derive that id differently (GenerateBracket
-- translates through a fresh domain-id -> storage-id map; RecordMatchResult
-- already has it, since its nodes come from getBracket).
--
-- assert documents that "not fully filled" here is an invariant violation
-- (DI-09/readyNodes), not a recoverable business outcome -- distinct from
-- MatchError-style Either failures, which represent expected outcomes.
createMatchForReadyNode
  :: (MatchRepository m, ParticipantRepository m)
  => TournamentId
  -> BracketId
  -> BracketNodeId
  -> BracketNode
  -> m MatchId
createMatchForReadyNode tid bracketId storageNodeId node =
  assert isReady $
  case (nodeSlotA node, nodeSlotB node) of
    (Filled pA, Filled pB) -> do
      pidA <- Repo.resolveParticipant pA
      pidB <- Repo.resolveParticipant pB
      Repo.createMatch NewMatch
        { newMatchTournament  = tid
        , newMatchBracket     = bracketId
        , newMatchBracketNode = storageNodeId  -- DI-12
        , newMatchCompetitorA = pidA
        , newMatchCompetitorB = pidB
        }
    _ -> error "impossible"
  where
    isReady = case (nodeSlotA node, nodeSlotB node) of
      (Filled _, Filled _) -> True
      _                    -> False
