module Application.UseCases.GetRoundRobinStandings
  ( getRoundRobinStandings
  , GetRoundRobinStandingsError(..)
  ) where

import Data.Bifunctor (first)

import Domain.Tournament (Tournament(..), TournamentId, TournamentFormat(..))
import Domain.Ids (UserId)

import Shell.Persistence.Port
  ( TournamentRepository
  , MatchRepository
  )
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization (AuthorizationError, requireTournamentVisible)
import Engine.Standings (Standing)
import qualified Engine.Standings as Standings

data GetRoundRobinStandingsError
  = Unauthorized AuthorizationError
  | NotRoundRobin TournamentFormat
  | BracketNotGenerated
  deriving (Eq, Show)

-- | Pure read, no Transactional constraint -- nothing here writes.
-- Valid mid-tournament: computeStandings already treats an unplayed
-- match as contributing 0 points (same as NoContest), so there is no
-- need to gate this on CompleteTournament's completion criterion.
--
-- Authorization runs before any state/existence check, matching every
-- write use case in this codebase -- checking format or bracket
-- existence first would let an unauthorized caller learn those facts
-- about a Private tournament before being told they can't view it.
getRoundRobinStandings
  :: (TournamentRepository m, MatchRepository m)
  => UserId
  -> TournamentId
  -> m (Either GetRoundRobinStandingsError [Standing])
getRoundRobinStandings caller tid = do
  tournament <- Repo.getTournament tid
  case first Unauthorized (requireTournamentVisible caller tournament) of
    Left err -> pure (Left err)
    Right () ->
      case tournamentFormat tournament of
        RoundRobin ->
          case tournamentBracket tournament of
            Nothing -> pure (Left BracketNotGenerated)
            Just bracketId -> do
              matches <- Repo.listMatchesForBracket bracketId
              pure (Right (Standings.computeStandings matches))
        other -> pure (Left (NotRoundRobin other))