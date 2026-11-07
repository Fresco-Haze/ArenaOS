module Application.UseCases.Predictions
  ( submitPrediction
  , myPredictions
  , leaderboard
  , PredictionError(..)
  , PredictionView(..)
  ) where

import Control.Monad (forM, unless, when)
import Data.Bifunctor (first)

import Domain.Ids (UserId)
import Domain.Match (Match(..), MatchId)
import Domain.Prediction (Pick)
import Domain.Tournament (Tournament(..), TournamentId)
import Engine.Predictions
  ( LeaderboardRow, PredictionResult, buildLeaderboard, pickAllowed, predictionOpen, scorePrediction )

import Shell.Persistence.Port
  ( MatchRepository, PredictionRepository, RegistrationRepository, TournamentRepository, Transactional(..) )
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization (AuthorizationError, requireVisibleToViewer)
import Application.Internal.LifecycleTransition (LifecycleError, requireOperationallyActive)

data PredictionError
  = Unauthorized AuthorizationError
  | InvalidLifecycle LifecycleError
  | NotAllowedToPredict   -- the organizer and registered players cannot predict their own tournament
  | PredictionsClosed     -- the match has started or finished
  | PickNotAllowed        -- a draw can only be picked in round robin
  deriving (Eq, Show)

data PredictionView = PredictionView
  { pvMatch  :: Match
  , pvPick   :: Pick
  , pvResult :: PredictionResult
  } deriving (Eq, Show)

-- | Saves a pick, or replaces the user's earlier pick for the same match.
submitPrediction
  :: ( MatchRepository m, TournamentRepository m, RegistrationRepository m
     , PredictionRepository m, Transactional m )
  => UserId -> MatchId -> Pick -> m (Either PredictionError ())
submitPrediction user mid pick =
  withTxEither $ do
    match      <- Repo.getMatch mid
    tournament <- Repo.getTournament (matchTournament match)
    registered <- Repo.listRegisteredUserIds (matchTournament match)
    case checks tournament registered match of
      Left err -> pure (Left err)
      Right () -> do
        Repo.savePrediction mid user pick
        pure (Right ())
  where
    checks tournament registered match = do
      first Unauthorized (requireVisibleToViewer (Just user) tournament)
      first InvalidLifecycle (requireOperationallyActive tournament)
      when (user == tournamentOwner tournament || user `elem` registered) (Left NotAllowedToPredict)
      unless (predictionOpen match) (Left PredictionsClosed)
      unless (pickAllowed (tournamentFormat tournament) pick) (Left PickNotAllowed)

-- | The user's own picks in one tournament, each with how it turned out.
myPredictions
  :: (MatchRepository m, TournamentRepository m, PredictionRepository m)
  => UserId -> TournamentId -> m (Either PredictionError [PredictionView])
myPredictions user tid = do
  tournament <- Repo.getTournament tid
  case first Unauthorized (requireVisibleToViewer (Just user) tournament) of
    Left err -> pure (Left err)
    Right () -> do
      picks <- Repo.listUserPredictions tid user
      views <- forM picks $ \(mid, pick) -> do
        m <- Repo.getMatch mid
        pure (PredictionView m pick (scorePrediction m pick))
      pure (Right views)

-- | One point per correct pick. Readable by anyone who can see the tournament.
leaderboard
  :: (MatchRepository m, TournamentRepository m, PredictionRepository m)
  => Maybe UserId -> TournamentId -> m (Either PredictionError [LeaderboardRow])
leaderboard viewer tid = do
  tournament <- Repo.getTournament tid
  case first Unauthorized (requireVisibleToViewer viewer tournament) of
    Left err -> pure (Left err)
    Right () -> do
      rows <- Repo.listTournamentPredictions tid
      scored <- forM rows $ \(mid, uid, pick) -> do
        m <- Repo.getMatch mid
        pure (uid, scorePrediction m pick)
      pure (Right (buildLeaderboard scored))
