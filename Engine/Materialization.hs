module Engine.Materialization
  ( materializeMatch
  , readyNodes
  , materializeReadyMatches
  ) where

import Data.Maybe (mapMaybe)
import Domain.Bracket (BracketId, BracketNode(..), BracketNodeId, MatchSlot(..))
import Domain.Match (Match(..), MatchId, MatchStatus(..))
import Domain.Tournament (TournamentId)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

-- | Turns a fully-resolved node (both slots Filled, per DI-09) into a
-- playable Match. Returns Nothing for any node not yet ready --
-- callers filter via readyNodes/materializeReadyMatches rather than
-- calling this directly on an arbitrary node.
isReady :: BracketNode -> Bool
isReady n = case (nodeSlotA n, nodeSlotB n) of
    (Filled _, Filled _) -> True
    _                    -> False

materializeMatch :: MatchId -> TournamentId -> BracketId -> Map BracketNodeId BracketNodeId -> BracketNode -> Maybe Match
materializeMatch mid tid bid idMap n = case (nodeSlotA n, nodeSlotB n) of
    (Filled a, Filled b) -> Just Match
        { matchId = mid
        , matchTournament = tid
        , matchBracket = bid
        , matchBracketNode =  case Map.lookup (nodeId n) idMap of
            Just sid -> sid
            Nothing       -> error ("materializeMatch: BracketNodeId " ++ show (nodeId n) ++ " missing from id map")
        , matchCompetitorA = a
        , matchCompetitorB = b
        , matchStatus = Scheduled
        , matchOutcome = Nothing
        }
    _ -> Nothing

readyNodes :: [BracketNode] -> [BracketNodeId]
readyNodes = map nodeId . filter isReady

  

-- | ids must already be freshly minted (one per ready node) by the
-- caller -- see the GenerateBracket use case, which calls this only
-- after createBracket has returned a real BracketId and createMatch
-- has minted a MatchId for each ready node.
materializeReadyMatches :: [MatchId] -> TournamentId -> BracketId-> Map BracketNodeId BracketNodeId -> [BracketNode] -> [Match]
materializeReadyMatches mids tid bid idMap nodes = [ m | (mid, node) <- zip mids (filter isReady nodes)
                                                 , Just m <- [materializeMatch mid tid bid idMap node] ]
                                        