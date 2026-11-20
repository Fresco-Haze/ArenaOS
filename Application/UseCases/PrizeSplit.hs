module Application.UseCases.PrizeSplit
  ( getPrizeSplitView
  , setPrizeSplit
  , clearTournamentPrizeSplit
  , PrizeSplitView(..)
  , PrizeSplitUseCaseError(..)
  ) where

import Domain.Ids (UserId)
import Domain.Tournament
  (Tournament(..), TournamentId, TournamentState(InProgress, Paused, Completed, Cancelled))

import Engine.PrizeSplit (PrizeSplitError, splitAmounts, validateSplit)
import Shell.Persistence.Port (TournamentRepository, PrizeSplitRepository, Transactional(..))
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization
  (AuthorizationError, requireTournamentOwner, requireVisibleToViewer)
import Application.Internal.LifecycleTransition (LifecycleError, requireTournamentStateNotIn)

data PrizeSplitView = PrizeSplitView
  { psvPrize    :: Maybe Int
  , psvPercents :: [Int]
  , psvAmounts  :: Maybe [Int]   -- Nothing when there is no prize or no split
  } deriving (Eq, Show)

data PrizeSplitUseCaseError
  = SplitUnauthorized AuthorizationError
  | SplitLifecycle LifecycleError
  | SplitNeedsPrize
  | SplitInvalid PrizeSplitError
  deriving (Eq, Show)

-- Anyone who can see the tournament. The amounts follow the current prize.
getPrizeSplitView
  :: (TournamentRepository m, PrizeSplitRepository m)
  => Maybe UserId -> TournamentId -> m (Either PrizeSplitUseCaseError PrizeSplitView)
getPrizeSplitView viewer tid = do
  tournament <- Repo.getTournament tid
  case requireVisibleToViewer viewer tournament of
    Left err -> pure (Left (SplitUnauthorized err))
    Right () -> do
      percents <- Repo.getPrizeSplit tid
      let prize = tournamentPrize tournament
          amounts = case (prize, percents) of
            (Just p, _ : _) -> Just (splitAmounts p percents)
            _               -> Nothing
      pure (Right (PrizeSplitView prize percents amounts))

-- Owner only, and only until the tournament starts.
setPrizeSplit
  :: (TournamentRepository m, PrizeSplitRepository m, Transactional m)
  => UserId -> TournamentId -> [Int] -> m (Either PrizeSplitUseCaseError ())
setPrizeSplit uid tid percents = do
  tournament <- Repo.getTournament tid
  case requireTournamentOwner uid tournament of
    Left err -> pure (Left (SplitUnauthorized err))
    Right () -> case requireTournamentStateNotIn [InProgress, Paused, Completed, Cancelled] tournament of
      Left err -> pure (Left (SplitLifecycle err))
      Right () -> case tournamentPrize tournament of
        Nothing -> pure (Left SplitNeedsPrize)
        Just _  -> case validateSplit percents of
          Left err -> pure (Left (SplitInvalid err))
          Right ok -> do
            withTxN (Repo.savePrizeSplit tid ok)
            pure (Right ())

-- Owner only, and only until the tournament starts.
clearTournamentPrizeSplit
  :: (TournamentRepository m, PrizeSplitRepository m)
  => UserId -> TournamentId -> m (Either PrizeSplitUseCaseError ())
clearTournamentPrizeSplit uid tid = do
  tournament <- Repo.getTournament tid
  case requireTournamentOwner uid tournament of
    Left err -> pure (Left (SplitUnauthorized err))
    Right () -> case requireTournamentStateNotIn [InProgress, Paused, Completed, Cancelled] tournament of
      Left err -> pure (Left (SplitLifecycle err))
      Right () -> do
        Repo.clearPrizeSplit tid
        pure (Right ())