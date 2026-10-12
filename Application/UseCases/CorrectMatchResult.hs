module Application.UseCases.CorrectMatchResult
  ( correctMatchResult
  , correctMatchResultInTx
  , CorrectMatchResultError(..)
  ) where

import Data.Bifunctor (first)
import Data.List (find)
import Control.Monad.IO.Class (liftIO)

import Domain.Match (Match(..), MatchId, MatchStatus(..), MatchOutcome(..))
import qualified Domain.Match as Match
import Domain.Tournament (Tournament(..), TournamentFormat(..))
import Domain.Participant (Participant)
import Domain.Ids (UserId)

import Shell.Persistence.Port
  ( MatchRepository, BracketRepository, TournamentRepository, EFootballScoreRepository, Transactional(..) )
import qualified Shell.Persistence.Port as Repo

import Engine.BracketGeneration (buildTopology, findParent)  -- findParent needs exporting
import Application.Internal.Authorization (AuthorizationError, requireTournamentOwner)
import qualified Domain.Tournament
import Data.Maybe (catMaybes, listToMaybe)
import Domain.Bracket (BracketNode(..), BracketNodeId, Bracket(..), BracketSide(..), MatchSlot(..))
import Domain.BracketLinks (BracketLinks, NodeDestination(..), NodeLinks(..), SlotPosition(..))
import Engine.Correction.DoubleEliminationLineage
  ( resolveWBWinnerTarget, resolveWBLoserTarget, resolveLBTarget
  , LineageError(..), GF1Outcome(..), classifyGF1Outcome
  )
import Application.Internal.LifecycleTransition (LifecycleError, requireOperationallyActive)


data CorrectMatchResultError
  = Unauthorized AuthorizationError
  | TournamentAlreadyCompleted
  | InvalidLifecycle LifecycleError
  | UnsupportedFormatForCorrection TournamentFormat
  | SourceMatchNotCompleted MatchStatus
  | CorrectedParticipantNotInMatch Participant
  | DownstreamMatchStarted MatchId
  | SourceMatchOutcomeInvalid MatchId
  | CorrectionIntegrityViolation MatchId
  | CorrectedOutcomeNotAdvanceable MatchOutcome
  | BracketLinksUnavailable
  deriving (Eq, Show)


correctMatchResult currentUser mid newOutcome =
  withTxEither (correctMatchResultInTx currentUser mid newOutcome)

correctMatchResultInTx currentUser mid newOutcome = do
  match      <- Repo.getMatch mid
  tournament <- Repo.getTournament (matchTournament match)
  case first Unauthorized (requireTournamentOwner currentUser tournament) of
    Left err -> pure (Left err)
    Right () ->
      case tournamentState tournament of
        Domain.Tournament.Completed -> pure (Left TournamentAlreadyCompleted)
        _ -> case first InvalidLifecycle (requireOperationallyActive tournament) of
          Left err -> pure (Left err)
          Right () -> case tournamentFormat tournament of
            SingleElimination -> dropStaleScore match newOutcome (guardAdvanceable newOutcome (correctSingleEliminationLinked match newOutcome))
            DoubleElimination -> dropStaleScore match newOutcome (guardAdvanceable newOutcome (correctDoubleElimination match newOutcome))
            format             -> pure (Left (UnsupportedFormatForCorrection format))

-- | A stored eFootball score describes the old result. If the correction changed
-- the winner it now contradicts the match, so drop it. A correction that
-- supplies goals writes its own score afterwards (correctEFootballResult).
dropStaleScore
  :: EFootballScoreRepository m
  => Match -> MatchOutcome
  -> m (Either CorrectMatchResultError Match)
  -> m (Either CorrectMatchResultError Match)
dropStaleScore match newOutcome act = do
  r <- act
  case r of
    Right _ | (matchOutcome match >>= correctedParticipant) /= correctedParticipant newOutcome ->
      Repo.deleteEFootballScore (matchId match)
    _ -> pure ()
  pure r

-- | Draw and NoContest carry no advancing participant, so correcting an
-- elimination match to either would save it and leave the old winner in the
-- next round. Record refuses these the same way (OutcomeNotAdvanceable).
guardAdvanceable
  :: Applicative m
  => MatchOutcome -> m (Either CorrectMatchResultError a) -> m (Either CorrectMatchResultError a)
guardAdvanceable outcome act =
  case correctedParticipant outcome of
    Nothing -> pure (Left (CorrectedOutcomeNotAdvanceable outcome))
    Just _  -> act
-- | Downstream path of a corrected node, followed through the STORED winner links,
-- so every id is a stored id (the ids matches and nodes carry). No links at all means
-- the bracket predates link storage: refuse, never fall back to template ids.
-- The step budget (the node count) stops a corrupt cyclic chain.
linkedDownstreamPath
  :: MatchId -> BracketNodeId -> [BracketNode] -> Maybe BracketLinks
  -> Either CorrectMatchResultError [BracketNodeId]
linkedDownstreamPath mid start nodes mLinks =
  case mLinks of
    Nothing    -> Left BracketLinksUnavailable
    Just links -> walk (length nodes) start links
  where
    walk budget nid links =
      case lookup nid links of
        Nothing -> Left (CorrectionIntegrityViolation mid)
        Just l  -> case linkWinnerTo l of
          Nothing -> Right []
          Just d
            | budget <= 0 -> Left (CorrectionIntegrityViolation mid)
            | otherwise   -> (destNode d :) <$> walk (budget - 1) (destNode d) links

-- | Reads and validates everything before any write happens.
correctSingleEliminationLinked
  :: (MatchRepository m, BracketRepository m)
  => Match -> MatchOutcome -> m (Either CorrectMatchResultError Match)
correctSingleEliminationLinked match newOutcome = do
  (_, nodes) <- Repo.getBracket (matchBracket match)
  mLinks <- Repo.getBracketLinks (matchBracket match)
  case linkedDownstreamPath (matchId match) (matchBracketNode match) nodes mLinks of
    Left err   -> pure (Left err)
    Right path -> correctSingleElimination path match newOutcome

-- | Everything that was previously inline in correctMatchResult's
-- SingleElimination branch, factored out unchanged so the dispatch
-- above stays a plain three-way switch.
correctSingleElimination
  :: (MatchRepository m, BracketRepository m)
  => [BracketNodeId] -> Match -> MatchOutcome -> m (Either CorrectMatchResultError Match)
correctSingleElimination path match newOutcome =
  case correctedParticipant newOutcome of
    Just newParticipant
      | newParticipant /= matchCompetitorA match
      , newParticipant /= matchCompetitorB match ->
        pure (Left (CorrectedParticipantNotInMatch newParticipant))
    _ -> do
      (bracket, nodes) <- Repo.getBracket (matchBracket match)

      allMatches <- Repo.listMatchesForBracket (matchBracket match)
      let downstreamMatches =
            [ m | nid <- path, Just m <- [find ((== nid) . matchBracketNode) allMatches] ]

      case downstreamMatches of
        (blocking : _) | matchStatus blocking /= Match.Scheduled ->
          pure (Left (DownstreamMatchStarted (matchId blocking)))
        _ ->
          case correctedParticipant newOutcome of
            Nothing ->
              let corrected = match { matchOutcome = Just newOutcome }
              in Repo.saveMatch corrected >> pure (Right corrected)
            Just newParticipant ->
              case matchOutcome match >>= correctedParticipant of
                Nothing ->
                  pure (Left (SourceMatchOutcomeInvalid (matchId match)))
                Just oldParticipant ->
                  applySingleElimCorrection bracket nodes allMatches path downstreamMatches
                    match newOutcome oldParticipant newParticipant

-- | Recording a result writes the bracket's node slots (RecordMatchResult), so a
-- correction must too: the node the winner advanced into takes the new winner and
-- the third-place node (fed by the loser) takes the new loser. Match records are
-- repaired the same way. A started bronze match blocks the correction.
applySingleElimCorrection
  :: (MatchRepository m, BracketRepository m)
  => Bracket -> [BracketNode] -> [Match] -> [BracketNodeId] -> [Match]
  -> Match -> MatchOutcome -> Participant -> Participant
  -> m (Either CorrectMatchResultError Match)
applySingleElimCorrection bracket nodes allMatches path downstreamMatches match newOutcome oldParticipant newParticipant =
  case bronzeMatch of
    Just b | matchStatus b /= Match.Scheduled ->
      pure (Left (DownstreamMatchStarted (matchId b)))
    _ ->
      case (nextUpdate, bronzeUpdate) of
        (Left e, _) -> pure (Left e)
        (_, Left e) -> pure (Left e)
        (Right mNext, Right mBronze) -> do
          Repo.saveMatch corrected
          mapM_ Repo.saveMatch (catMaybes [mNext, mBronze])
          mapM_ Repo.updateNodeSlots repairedNodes
          pure (Right corrected)
  where
    corrected = match { matchOutcome = Just newOutcome }
    oldLoser  = otherCompetitor match oldParticipant
    newLoser  = otherCompetitor match newParticipant
    bronzeMatch = do
      tp <- bracketThirdPlaceNodeId bracket
      b  <- find ((== tp) . matchBracketNode) allMatches
      if matchCompetitorA b == oldLoser || matchCompetitorB b == oldLoser
        then Just b
        else Nothing
    nextUpdate = case downstreamMatches of
      []            -> Right Nothing
      nextMatch : _ -> case findReplacementSlot nextMatch oldParticipant newParticipant of
        Nothing      -> Left (CorrectionIntegrityViolation (matchId nextMatch))
        Just updated -> Right (Just updated)
    bronzeUpdate = case bronzeMatch of
      Nothing -> Right Nothing
      Just b  -> case findReplacementSlot b oldLoser newLoser of
        Nothing      -> Left (CorrectionIntegrityViolation (matchId b))
        Just updated -> Right (Just updated)
    repairedNodes =
      slotRepairs (bracketThirdPlaceNodeId bracket) path nodes
        (oldParticipant, newParticipant) (oldLoser, newLoser)

otherCompetitor :: Match -> Participant -> Participant
otherCompetitor m p
  | p == matchCompetitorA m = matchCompetitorB m
  | otherwise               = matchCompetitorA m

-- | Replaces old with new in whichever slot of the node holds it, if either does.
swapInNode :: Participant -> Participant -> BracketNode -> Maybe BracketNode
swapInNode old new n
  | nodeSlotA n == Filled old = Just n { nodeSlotA = Filled new }
  | nodeSlotB n == Filled old = Just n { nodeSlotB = Filled new }
  | otherwise                 = Nothing

slotRepairs
  :: Maybe BracketNodeId -> [BracketNodeId] -> [BracketNode]
  -> (Participant, Participant) -> (Participant, Participant)
  -> [BracketNode]
slotRepairs mThirdPlace path nodes (oldWinner, newWinner) (oldLoser, newLoser) =
  catMaybes
    [ do pid <- listToMaybe path
         n   <- find ((== pid) . nodeId) nodes
         swapInNode oldWinner newWinner n
    , do tp <- mThirdPlace
         n  <- find ((== tp) . nodeId) nodes
         swapInNode oldLoser newLoser n
    ]

-- | What a correction of a double-elimination node must touch, decided from the bracket
-- header (grand final, reset) and the STORED links, so every id is a stored id.
-- A winners node needs both destinations (the winners final's winner goes to the grand
-- final); a losers node needs its winner destination (the losers final's goes to the
-- grand final). Anything missing is refused, as the old code refused "no loser target".
data DEPlan
  = PlanReset
  | PlanGF1 BracketNodeId
  | PlanWB BracketNodeId BracketNodeId
  | PlanLB BracketNodeId

planDECorrection
  :: MatchId -> Bracket -> BracketLinks -> BracketNode -> Either CorrectMatchResultError DEPlan
planDECorrection mid bracket links sourceNode
  | Just sid == bracketGF1NodeId bracket =
      case bracketResetNodeId bracket of
        Just resetId -> Right (PlanGF1 resetId)
        Nothing      -> Left (CorrectionIntegrityViolation mid)
  | Just sid == bracketResetNodeId bracket = Right PlanReset
  | otherwise =
      case lookup sid links of
        Nothing -> Left (CorrectionIntegrityViolation mid)
        Just l
          | nodeStage sourceNode == Winners ->
              case (linkWinnerTo l, linkLoserTo l) of
                (Just w, Just lo) -> Right (PlanWB (destNode w) (destNode lo))
                _                 -> Left (CorrectionIntegrityViolation mid)
          | otherwise ->
              case linkWinnerTo l of
                Just w  -> Right (PlanLB (destNode w))
                Nothing -> Left (CorrectionIntegrityViolation mid)
  where
    sid = nodeId sourceNode

-- | The winners-bracket final winner, found as the node whose winner goes to slot A of
-- the grand final (how buildDoubleEliminationTopology wires it), not by template lookup.
findWBFinalWinnerLinked
  :: BracketLinks -> BracketNodeId -> [Match] -> MatchId
  -> Either CorrectMatchResultError Participant
findWBFinalWinnerLinked links gf1Id allMatches currentMatchId =
  case [ nid | (nid, l) <- links, linkWinnerTo l == Just (NodeDestination gf1Id SlotA) ] of
    [wbFinalId] ->
      case find ((== wbFinalId) . matchBracketNode) allMatches of
        Nothing -> Left (CorrectionIntegrityViolation currentMatchId)
        Just wbFinalMatch ->
          case matchOutcome wbFinalMatch >>= correctedParticipant of
            Nothing -> Left (SourceMatchOutcomeInvalid (matchId wbFinalMatch))
            Just w  -> Right w
    _ -> Left (CorrectionIntegrityViolation currentMatchId)

correctDoubleElimination
  :: (MatchRepository m, BracketRepository m)
  => Match -> MatchOutcome -> m (Either CorrectMatchResultError Match)
correctDoubleElimination match newOutcome = do
  (bracket, nodes) <- Repo.getBracket (matchBracket match)
  mLinks <- Repo.getBracketLinks (matchBracket match)
  case mLinks of
    Nothing -> pure (Left BracketLinksUnavailable)
    Just links ->
      case find ((== matchBracketNode match) . nodeId) nodes of
        Nothing -> pure (Left (CorrectionIntegrityViolation (matchId match)))
        Just sourceNode ->
          case planDECorrection (matchId match) bracket links sourceNode of
            Left err -> pure (Left err)
            Right plan -> do
              allMatches <- Repo.listMatchesForBracket (matchBracket match)
              case plan of
                PlanReset ->
                  applySourceOnlyCorrection match newOutcome
                PlanWB winnerTargetId loserTargetId ->
                  handleWBSource match newOutcome allMatches winnerTargetId loserTargetId
                PlanLB targetId ->
                  handleLBSource match newOutcome allMatches targetId
                PlanGF1 resetId ->
                  handleGF1Case match newOutcome
                    (findWBFinalWinnerLinked links (nodeId sourceNode) allMatches (matchId match))
                    allMatches resetId

-- | Static downstream path from a corrected node's id up to the root,
-- using the RECOMPUTED topology shape (buildTopology size) rather than
-- live BracketNode state -- propagateWinner destroys the
-- AwaitingWinnerOf pointer the instant it fills a slot (SE-CORR-02).
-- Single-Elim only: relies on findParent producing a single linear
-- chain, which does not generalize to Double Elim.
downstreamPath :: BracketNodeId -> Int -> [BracketNodeId]
downstreamPath sourceId size = go sourceId
  where
    topology = buildTopology size
    go nid = case findParent nid topology of
      Nothing     -> []
      Just parent -> parent : go parent

correctedParticipant :: MatchOutcome -> Maybe Participant
correctedParticipant (Winner p)           = Just p
correctedParticipant (Forfeit p)          = Just p
correctedParticipant (Disqualification p) = Just p
correctedParticipant Draw                 = Nothing
correctedParticipant NoContest            = Nothing

-- | Pure, domain-neutral: swaps oldParticipant for newParticipant in
-- whichever of the match's two competitor slots currently holds it.
-- Nothing means oldParticipant isn't actually present in either slot --
-- the use case is responsible for turning that into
-- CorrectionIntegrityViolation; this function makes no error-type
-- decision of its own (SE-CORR-04).
findReplacementSlot :: Match -> Participant -> Participant -> Maybe Match
findReplacementSlot m oldParticipant newParticipant
  | matchCompetitorA m == oldParticipant = Just m { matchCompetitorA = newParticipant }
  | matchCompetitorB m == oldParticipant = Just m { matchCompetitorB = newParticipant }
  | otherwise                            = Nothing


data DECase = WBNonFinal | WBFinal | LBNonFinal | LBFinal | GF1Case | ResetCase
  deriving (Eq, Show)

classifyDECase :: Bracket -> [BracketNode] -> Int -> BracketNode -> DECase
classifyDECase bracket wbNodes size sourceNode
  | Just (nodeId sourceNode) == bracketGF1NodeId bracket   = GF1Case
  | Just (nodeId sourceNode) == bracketResetNodeId bracket = ResetCase
  | nodeStage sourceNode == Winners =
      case resolveWBWinnerTarget size (nodeId sourceNode) of
        Nothing -> WBFinal
        Just _  -> WBNonFinal
  | otherwise =
      case resolveLBTarget wbNodes size (nodeId sourceNode) of
        Nothing -> LBFinal
        Just _  -> LBNonFinal

translateLineageError :: Match -> LineageError -> CorrectMatchResultError
translateLineageError match (NoLoserTarget _) = CorrectionIntegrityViolation (matchId match)



-- | DE counterpart of slotRepairs. Recording writes the winner into the winner
-- target node and the loser into the loser target node (propagateWinner /
-- propagateLoser), so a correction must swap them there too. A target with no
-- Match row yet still has filled slots, so this works on nodes alone.
repairTargetSlots
  :: (BracketRepository m)
  => Match -> MatchOutcome -> Maybe BracketNodeId -> Maybe BracketNodeId -> m ()
repairTargetSlots match newOutcome winnerTarget loserTarget =
  case (correctedParticipant newOutcome, matchOutcome match >>= correctedParticipant) of
    (Just newWinner, Just oldWinner) -> do
      (_, nodes) <- Repo.getBracket (matchBracket match)
      let repairs = catMaybes
            [ winnerTarget >>= \t -> find ((== t) . nodeId) nodes >>= swapInNode oldWinner newWinner
            , loserTarget  >>= \t -> find ((== t) . nodeId) nodes >>= swapInNode newWinner oldWinner
            ]
      mapM_ Repo.updateNodeSlots repairs
    _ -> pure ()
validateTarget :: Maybe Match -> Either CorrectMatchResultError ()
validateTarget Nothing = Right ()
validateTarget (Just m)
  | matchStatus m == Match.Scheduled = Right ()
  | otherwise = Left (DownstreamMatchStarted (matchId m))

applySourceOnlyCorrection
  :: (MatchRepository m) => Match -> MatchOutcome -> m (Either CorrectMatchResultError Match)
applySourceOnlyCorrection match newOutcome = do
  let corrected = match { matchOutcome = Just newOutcome }
  Repo.saveMatch corrected
  pure (Right corrected)

applyDualTargetCorrection
  :: (MatchRepository m)
  => Match -> MatchOutcome -> Maybe Match -> Maybe Match
  -> m (Either CorrectMatchResultError Match)
applyDualTargetCorrection match newOutcome winnerTargetMatch loserTargetMatch =
  case (correctedParticipant newOutcome, matchOutcome match >>= correctedParticipant) of
    (Nothing, _) -> applySourceOnlyCorrection match newOutcome
    (_, Nothing) -> pure (Left (SourceMatchOutcomeInvalid (matchId match)))
    (Just newWinner, Just oldWinner) ->
      let repairWith f mtm = case mtm of
            Nothing -> Right Nothing
            Just tm -> case f tm of
              Nothing      -> Left (CorrectionIntegrityViolation (matchId tm))
              Just updated -> Right (Just updated)
      in case ( repairWith (\tm -> findReplacementSlot tm oldWinner newWinner) winnerTargetMatch
              , repairWith (\tm -> findReplacementSlot tm newWinner oldWinner) loserTargetMatch
              ) of
           (Left e, _) -> pure (Left e)
           (_, Left e) -> pure (Left e)
           (Right mW, Right mL) -> do
             let corrected = match { matchOutcome = Just newOutcome }
             Repo.saveMatch corrected
             mapM_ Repo.saveMatch (catMaybes [mW, mL])
             pure (Right corrected)

handleWBSource
  :: (MatchRepository m, BracketRepository m)
  => Match -> MatchOutcome -> [Match] -> BracketNodeId -> BracketNodeId
  -> m (Either CorrectMatchResultError Match)
handleWBSource match newOutcome allMatches winnerTargetId loserTargetId = do
  let winnerTargetMatch = find ((== winnerTargetId) . matchBracketNode) allMatches
      loserTargetMatch  = find ((== loserTargetId)  . matchBracketNode) allMatches
  case validateTarget winnerTargetMatch *> validateTarget loserTargetMatch of
    Left err -> pure (Left err)
    Right () -> do
      r <- applyDualTargetCorrection match newOutcome winnerTargetMatch loserTargetMatch
      case r of
        Right _ -> repairTargetSlots match newOutcome (Just winnerTargetId) (Just loserTargetId)
        Left _  -> pure ()
      pure r

handleLBSource
  :: (MatchRepository m, BracketRepository m)
  => Match -> MatchOutcome -> [Match] -> BracketNodeId
  -> m (Either CorrectMatchResultError Match)
handleLBSource match newOutcome allMatches targetId = do
  let targetMatch = find ((== targetId) . matchBracketNode) allMatches
  case validateTarget targetMatch of
    Left err -> pure (Left err)
    Right () ->
      case (correctedParticipant newOutcome, matchOutcome match >>= correctedParticipant) of
        (Nothing, _) -> applySourceOnlyCorrection match newOutcome
        (_, Nothing) -> pure (Left (SourceMatchOutcomeInvalid (matchId match)))
        (Just newWinner, Just oldWinner) -> do
          repairTargetSlots match newOutcome (Just targetId) Nothing
          case targetMatch of
            Nothing -> applySourceOnlyCorrection match newOutcome
            Just tm ->
              case findReplacementSlot tm oldWinner newWinner of
                Nothing -> pure (Left (CorrectionIntegrityViolation (matchId tm)))
                Just updatedTm -> do
                  let corrected = match { matchOutcome = Just newOutcome }
                  Repo.saveMatch corrected
                  Repo.saveMatch updatedTm
                  pure (Right corrected)

findWBFinalWinner
  :: Int -> [BracketNode] -> [Match] -> MatchId
  -> Either CorrectMatchResultError Participant
findWBFinalWinner size wbNodes allMatches currentMatchId =
  case find (\n -> resolveWBWinnerTarget size (nodeId n) == Nothing) wbNodes of
    Nothing -> Left (CorrectionIntegrityViolation currentMatchId)
    Just wbFinalNode ->
      case find ((== nodeId wbFinalNode) . matchBracketNode) allMatches of
        Nothing -> Left (CorrectionIntegrityViolation currentMatchId)
        Just wbFinalMatch ->
          case matchOutcome wbFinalMatch >>= correctedParticipant of
            Nothing -> Left (SourceMatchOutcomeInvalid (matchId wbFinalMatch))
            Just w  -> Right w

-- 2. checkGF1Correction gains the explicit reject Thread A specified.
-- Needs the current match's id threaded in to construct the error.
checkGF1Correction
  :: MatchId -> BracketNodeId -> GF1Outcome -> GF1Outcome -> Maybe Match
  -> Either CorrectMatchResultError (Maybe MatchId)
checkGF1Correction currentMatchId _ oldOutcome newOutcome resetMatch =
  case (oldOutcome, newOutcome) of
    (ResetRequired, Decisive) -> case resetMatch of
      Nothing -> Right Nothing
      Just m | matchStatus m == Match.Scheduled  -> Right (Just (matchId m))
             | matchStatus m == Match.InProgress -> Left (DownstreamMatchStarted (matchId m))
             | matchStatus m == Match.Completed  -> Left TournamentAlreadyCompleted
    (Decisive, ResetRequired) -> Left (CorrectionIntegrityViolation currentMatchId)
      -- Thread A's explicit, documented exception: would require
      -- materializing a reset match that never existed.
    _ -> Right Nothing  -- Decisive->Decisive, ResetRequired->ResetRequired: no structural change


handleGF1Case
  :: (MatchRepository m, BracketRepository m)
  => Match -> MatchOutcome -> Either CorrectMatchResultError Participant -> [Match] -> BracketNodeId
  -> m (Either CorrectMatchResultError Match)
handleGF1Case match newOutcome wbFinalWinnerResult allMatches resetNodeId =
  case wbFinalWinnerResult of
    Left err -> pure (Left err)
    Right wbFinalWinner ->
      case (correctedParticipant newOutcome, matchOutcome match >>= correctedParticipant) of
        (Nothing, _) -> pure (Left (SourceMatchOutcomeInvalid (matchId match)))
        (_, Nothing) -> pure (Left (SourceMatchOutcomeInvalid (matchId match)))
        (Just newGF1Winner, Just oldGF1Winner) ->
          let oldOutcomeClass = classifyGF1Outcome wbFinalWinner oldGF1Winner
              newOutcomeClass = classifyGF1Outcome wbFinalWinner newGF1Winner
              resetMatch      = find ((== resetNodeId) . matchBracketNode) allMatches
          in case checkGF1Correction (matchId match) resetNodeId oldOutcomeClass newOutcomeClass resetMatch of
               Left err -> pure (Left err)
               Right maybeRetract -> do
                 mapM_ Repo.deleteMatch maybeRetract
                 -- Record voids the reset node to (ByeSlot, ByeSlot) when no reset is
                 -- needed, so retracting the reset must leave the node the same way.
                 if oldOutcomeClass == ResetRequired && newOutcomeClass == Decisive
                   then do
                     (_, nodes) <- Repo.getBracket (matchBracket match)
                     mapM_ (\n -> Repo.updateNodeSlots n { nodeSlotA = ByeSlot, nodeSlotB = ByeSlot })
                           (find ((== resetNodeId) . nodeId) nodes)
                   else pure ()
                 applySourceOnlyCorrection match newOutcome
         