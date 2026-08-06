module Application.UseCases.StartMatch
  ( startMatch
  , StartMatchError(..)
  ) where

import Data.Bifunctor (first)

import Domain.Match (Match(..), MatchId, MatchStatus(..))
import Domain.MatchError (MatchError(..))
import Domain.Ids (UserId)

import Shell.Persistence.Port (MatchRepository, TournamentRepository)
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization (AuthorizationError, requireTournamentOwner)

data StartMatchError
  = Unauthorized AuthorizationError
  | InvalidMatch MatchError
  deriving (Eq, Show)

startMatch
  :: (MatchRepository m, TournamentRepository m)
  => UserId
  -> MatchId
  -> m (Either StartMatchError Match)
startMatch currentUser matchId = do
  match      <- Repo.getMatch matchId
  tournament <- Repo.getTournament (matchTournament match)

  case first Unauthorized (requireTournamentOwner currentUser tournament) of
    Left err -> pure (Left err)
    Right () ->
      fmap (first InvalidMatch) $ case matchStatus match of
        Scheduled -> do
          let updated = match { matchStatus = InProgress }
          Repo.saveMatch updated
          pure (Right updated)
        status -> pure (Left (MatchNotScheduled status))