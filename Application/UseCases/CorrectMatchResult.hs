module Application.UseCases.CorrectMatchResult
  ( correctMatchResult
  , CorrectMatchResultError(..)
  ) where

import Data.Bifunctor (first)
import Data.List (find)
import Control.Monad.IO.Class (liftIO)

import Domain.Match (Match(..), MatchId, MatchStatus(..), MatchOutcome(..))
import qualified Domain.Match as Match
import Domain.Bracket (BracketNode(..), BracketNodeId)
import Domain.Tournament (Tournament(..), TournamentFormat(..))
import Domain.Participant (Participant)
import Domain.Ids (UserId)

import Shell.Persistence.Port
  ( MatchRepository, BracketRepository, TournamentRepository, Transactional(..) )
import qualified Shell.Persistence.Port as Repo

import Engine.BracketGeneration (buildTopology, findParent)  -- findParent needs exporting
import Application.Internal.Authorization (AuthorizationError, requireTournamentOwner)
import qualified Domain.Tournament

data CorrectMatchResultError
  = Unauthorized AuthorizationError
  | TournamentAlreadyCompleted
  | UnsupportedFormatForCorrection TournamentFormat
  | SourceMatchNotCompleted MatchStatus
  | CorrectedParticipantNotInMatch Participant
  | DownstreamMatchStarted MatchId
  | SourceMatchOutcomeInvalid MatchId
  | CorrectionIntegrityViolation MatchId
  deriving (Eq, Show)

correctMatchResult
  :: ( MatchRepository m, BracketRepository m, TournamentRepository m
     , Transactional m )
  => UserId -> MatchId -> MatchOutcome
  -> m (Either CorrectMatchResultError Match)
correctMatchResult currentUser mid newOutcome = withTxEither $ do
  match      <- Repo.getMatch mid
  tournament <- Repo.getTournament (matchTournament match)
  case first Unauthorized (requireTournamentOwner currentUser tournament) of
    Left err -> pure (Left err)
    Right () ->
      case tournamentState tournament of
        Domain.Tournament.Completed -> pure (Left TournamentAlreadyCompleted)
        _ ->
          case tournamentFormat tournament of
            format | format /= SingleElimination ->
              pure (Left (UnsupportedFormatForCorrection format))
            _ ->
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
                          -- Draw/NoContest: nothing ever propagated from this
                          -- match (RecordMatchResult already rejects these
                          -- for SingleElim), so only the source changes.
                          let corrected = match { matchOutcome = Just newOutcome }
                          in Repo.saveMatch corrected >> pure (Right corrected)
                        Just newParticipant ->
                          case matchOutcome match >>= correctedParticipant of
                            Nothing ->
                              pure (Left (SourceMatchOutcomeInvalid mid))
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