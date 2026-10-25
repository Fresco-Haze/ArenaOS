module Application.UseCases.ListMyTournaments
  ( listMyTournaments
  , MatchSummary(..)
  , myMatchSummary
  ) where

import Data.List (sortBy)
import Data.Maybe (listToMaybe)
import Data.Ord (comparing)

import Domain.Ids (UserId)
import qualified Domain.Match as M
import Domain.Registration (registrationParticipant)
import Domain.Tournament (Tournament(..), TournamentState(InProgress, Paused, Completed))
import Engine.Champion (tournamentChampion)
import Shell.Persistence.Port (TournamentRepository, RegistrationRepository, MatchRepository, BracketRepository)
import qualified Shell.Persistence.Port as Repo

listMyTournaments :: TournamentRepository m => UserId -> m [Tournament]
listMyTournaments = Repo.listTournamentsByOwner

-- The signed-in player's next unfinished match, and how many tournaments they won.
-- Only registrations linked to an account count; players the organizer typed in
-- by hand have no account.
data MatchSummary = MatchSummary
  { msNext :: Maybe (Tournament, M.Match)
  , msWon  :: Int
  }

myMatchSummary
  :: (TournamentRepository m, RegistrationRepository m, MatchRepository m, BracketRepository m)
  => UserId
  -> m MatchSummary
myMatchSummary uid = do
  tids <- Repo.listRegisteredTournamentIds uid
  perT <- mapM forTournament tids
  let candidates = concatMap fst perT
      won = sum (map snd perT)
  pure (MatchSummary (listToMaybe (sortBy (comparing order) candidates)) won)
  where
    order (_, m) = case M.matchScheduledStart m of
      Just s  -> (0 :: Int, Just s)
      Nothing -> (1, Nothing)

    forTournament tid = do
      t <- Repo.getTournament tid
      mrid <- Repo.findUserRegistration tid uid
      case (tournamentBracket t, mrid) of
        (Just bid, Just rid) -> do
          reg <- Repo.getRegistration rid
          ms <- Repo.listMatchesForBracket bid
          let me = registrationParticipant reg
              running = tournamentState t `elem` [InProgress, Paused]
              open m = M.matchStatus m `elem` [M.Scheduled, M.InProgress]
              mine m = M.matchCompetitorA m == me || M.matchCompetitorB m == me
              nextOnes = [ (t, m) | running, m <- ms, mine m, open m ]
          champ <- if tournamentState t == Completed
                     then do
                       (br, nodes) <- Repo.getBracket bid
                       pure (tournamentChampion (tournamentFormat t) br nodes ms)
                     else pure Nothing
          pure (nextOnes, if champ == Just me then 1 else 0)
        _ -> pure ([], 0)