module Application.UseCases.StartMatch
  ( startMatch
  ) where

import Domain.Match (Match(..), MatchId, MatchStatus(..))
import Domain.MatchError (MatchError(..))

import Shell.Persistence.Port (MatchRepository)
import qualified Shell.Persistence.Port as Repo

startMatch :: MatchRepository m => MatchId -> m (Either MatchError Match)
startMatch matchId = do
  match <- Repo.getMatch matchId
  case matchStatus match of
    Scheduled -> do
      let updated = match { matchStatus = InProgress }
      Repo.saveMatch updated
      pure (Right updated)
    status -> pure (Left (MatchNotScheduled status))