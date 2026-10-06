module Application.UseCases.RecordEFootballResult
  ( recordEFootballResult
  , RecordEFootballResultError(..)
  , correctEFootballResult
  , CorrectEFootballResultError(..)
  ) where

--import Data.Bifunctor (first)


import Domain.Match (Match(..), MatchId(..), MatchOutcome(..))
--import Domain.MatchOutcome (MatchOutcome(..))  -- adjust import path if this lives elsewhere
import Domain.Scoreable (EFootballScore, ScoreComparison(..), compareScores)
import Domain.Ids (UserId)

import Shell.Persistence.Port
  ( EFootballScoreRepository
  , MatchRepository
  , BracketRepository
  , ParticipantRepository
  , TournamentRepository
  , Transactional(..)
  )
import qualified Shell.Persistence.Port as Repo

import Application.UseCases.RecordMatchResult
  ( recordMatchResultInTx
  , RecordMatchResultError
  )
import Application.UseCases.CorrectMatchResult
  ( correctMatchResultInTx
  , CorrectMatchResultError
  )

data RecordEFootballResultError
  = MatchResultError RecordMatchResultError
  deriving (Eq, Show)

recordEFootballResult
  :: ( EFootballScoreRepository m
     , MatchRepository m
     , BracketRepository m
     , ParticipantRepository m
     , TournamentRepository m
     , Transactional m
     )
  => UserId
  -> MatchId
  -> EFootballScore
  -> EFootballScore
  -> m (Either RecordEFootballResultError Match)
recordEFootballResult currentUser mid scoreA scoreB =
  withTxEither $ do
    match <- Repo.getMatch mid
    let outcome = deriveOutcome match scoreA scoreB
    outcomeResult <- recordMatchResultInTx currentUser mid outcome
    case outcomeResult of
      Left err -> pure (Left (MatchResultError err))
      Right updatedMatch -> do
        Repo.saveEFootballScore mid scoreA scoreB
        pure (Right updatedMatch)

data CorrectEFootballResultError
  = EFootballCorrectionFailed CorrectMatchResultError
  deriving (Eq, Show)

-- | Corrects a match's result by supplying new goals. The outcome is derived
-- from the goals (as in recordEFootballResult), the correction runs through
-- correctMatchResultInTx, and the new score is written only if it succeeded.
-- A correction that changes the winner has already dropped the stale score by
-- then; one that keeps the winner is simply overwritten here.
correctEFootballResult
  :: ( EFootballScoreRepository m
     , MatchRepository m
     , BracketRepository m
     , TournamentRepository m
     , Transactional m
     )
  => UserId
  -> MatchId
  -> EFootballScore
  -> EFootballScore
  -> m (Either CorrectEFootballResultError Match)
correctEFootballResult currentUser mid scoreA scoreB =
  withTxEither $ do
    match <- Repo.getMatch mid
    r <- correctMatchResultInTx currentUser mid (deriveOutcome match scoreA scoreB)
    case r of
      Left err -> pure (Left (EFootballCorrectionFailed err))
      Right updated -> do
        Repo.saveEFootballScore mid scoreA scoreB
        pure (Right updated)

-- | Translates a score comparison into the generic MatchOutcome vocabulary,
-- using the already-fetched Match to resolve "first"/"second" into the
-- actual competing Participants.
deriveOutcome :: Match -> EFootballScore -> EFootballScore -> MatchOutcome
deriveOutcome match scoreA scoreB = case compareScores scoreA scoreB of
  FirstWins  -> Winner (matchCompetitorA match)
  SecondWins -> Winner (matchCompetitorB match)
  Tied       -> Draw