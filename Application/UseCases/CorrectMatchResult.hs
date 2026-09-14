module Application.UseCases.CorrectMatchResult
  ( correctMatchResult
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
  ( MatchRepository, BracketRepository, TournamentRepository, Transactional(..) )
import qualified Shell.Persistence.Port as Repo

import Engine.BracketGeneration (buildTopology, findParent)  -- findParent needs exporting
import Application.Internal.Authorization (AuthorizationError, requireTournamentOwner)
import qualified Domain.Tournament
import Data.Maybe (catMaybes)
import Domain.Bracket (BracketNode(..), BracketNodeId, Bracket(..), BracketSide(..))
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
  deriving (Eq, Show)


correctMatchResult currentUser mid newOutcome = withTxEither $ do
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
            SingleElimination -> correctSingleElimination match newOutcome
            DoubleElimination -> correctDoubleElimination match newOutcome
            format             -> pure (Left (UnsupportedFormatForCorrection format))

-- | Everything that was previously inline in correctMatchResult's
-- SingleElimination branch, factored out unchanged so the dispatch
-- above stays a plain three-way switch.
correctSingleElimination
  :: (MatchRepository m, BracketRepository m)
  => Match -> MatchOutcome -> m (Either CorrectMatchResultError Match)
correctSingleElimination match newOutcome =
  case correctedParticipant newOutcome of
    Just newParticipant
      | newParticipant /= matchCompetitorA match
      , newParticipant /= matchCompetitorB match ->
        pure (Left (CorrectedParticipantNotInMatch newParticipant))
    _ -> do
      (_, nodes) <- Repo.getBracket (matchBracket match)
      let size = length (filter ((== 1) . nodeRound) nodes) * 2
          path = downstreamPath (matchBracketNode match) size

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
                Just oldParticipant -> do
                  case downstreamMatches of
                    [] -> do
                      let corrected = match { matchOutcome = Just newOutcome }
                      Repo.saveMatch corrected
                      pure (Right corrected)
                    nextMatch : _ ->
                      case findReplacementSlot nextMatch oldParticipant newParticipant of
                        Nothing ->
                          pure (Left (CorrectionIntegrityViolation (matchId nextMatch)))
                        Just updated -> do
                          let corrected = match { matchOutcome = Just newOutcome }
                          Repo.saveMatch corrected
                          Repo.saveMatch updated
                          pure (Right corrected)

correctDoubleElimination
  :: (MatchRepository m, BracketRepository m)
  => Match -> MatchOutcome -> m (Either CorrectMatchResultError Match)
correctDoubleElimination match newOutcome = do
  (bracket, nodes) <- Repo.getBracket (matchBracket match)
  let size = length (filter (\n -> nodeRound n == 1 && nodeStage n == Winners) nodes) * 2
      realWBRound1      = filter (\n -> nodeRound n == 1 && nodeStage n == Winners) nodes
      freshLaterRounds  = filter ((> 1) . nodeRound) (buildTopology size)
      wbNodes           = realWBRound1 ++ freshLaterRounds
      sourceNodeId      = matchBracketNode match
  case find ((== sourceNodeId) . nodeId) nodes of
    Nothing -> pure (Left (CorrectionIntegrityViolation (matchId match)))
    Just sourceNode -> do
      allMatches <- Repo.listMatchesForBracket (matchBracket match)
      case classifyDECase bracket wbNodes size sourceNode of
        ResetCase -> applySourceOnlyCorrection match newOutcome

        WBNonFinal ->
          case ( resolveWBWinnerTarget size sourceNodeId
               , resolveWBLoserTarget wbNodes size sourceNodeId
               ) of
            (Nothing, _) -> pure (Left (CorrectionIntegrityViolation (matchId match)))
              -- unreachable: classifyDECase already confirmed this isn't the WB Final
            (Just winnerTargetId, loserResult) ->
              case loserResult of
                Left lerr -> pure (Left (translateLineageError match lerr))
                Right loserTargetId ->
                  handleWBSource match newOutcome allMatches winnerTargetId loserTargetId

        WBFinal ->
          case bracketGF1NodeId bracket of
            Nothing -> pure (Left (CorrectionIntegrityViolation (matchId match)))
              -- unreachable for a genuine DE bracket, per GenerateBracket.hs
            Just gf1Id ->
              case resolveWBLoserTarget wbNodes size sourceNodeId of
                Left lerr -> pure (Left (translateLineageError match lerr))
                Right lbFinalId -> handleWBSource match newOutcome allMatches gf1Id lbFinalId

        LBNonFinal ->
          case resolveLBTarget wbNodes size sourceNodeId of
            Nothing -> pure (Left (CorrectionIntegrityViolation (matchId match)))
              -- unreachable: classifyDECase already confirmed this isn't the LB Final
            Just targetId -> handleLBSource match newOutcome allMatches targetId

        LBFinal ->
          case bracketGF1NodeId bracket of
            Nothing -> pure (Left (CorrectionIntegrityViolation (matchId match)))
            Just gf1Id -> handleLBSource match newOutcome allMatches gf1Id

        GF1Case ->
          case bracketResetNodeId bracket of
            Nothing -> pure (Left (CorrectionIntegrityViolation (matchId match)))
              -- unreachable for a genuine DE bracket
            Just resetId -> handleGF1Case match newOutcome size wbNodes allMatches resetId

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
  :: (MatchRepository m)
  => Match -> MatchOutcome -> [Match] -> BracketNodeId -> BracketNodeId
  -> m (Either CorrectMatchResultError Match)
handleWBSource match newOutcome allMatches winnerTargetId loserTargetId = do
  let winnerTargetMatch = find ((== winnerTargetId) . matchBracketNode) allMatches
      loserTargetMatch  = find ((== loserTargetId)  . matchBracketNode) allMatches
  case validateTarget winnerTargetMatch *> validateTarget loserTargetMatch of
    Left err -> pure (Left err)
    Right () -> applyDualTargetCorrection match newOutcome winnerTargetMatch loserTargetMatch

handleLBSource
  :: (MatchRepository m)
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
        (Just newWinner, Just oldWinner) ->
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
  :: (MatchRepository m)
  => Match -> MatchOutcome -> Int -> [BracketNode] -> [Match] -> BracketNodeId
  -> m (Either CorrectMatchResultError Match)
handleGF1Case match newOutcome size wbNodes allMatches resetNodeId =
  case findWBFinalWinner size wbNodes allMatches (matchId match) of
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
                 applySourceOnlyCorrection match newOutcome
         