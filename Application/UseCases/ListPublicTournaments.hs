module Application.UseCases.ListPublicTournaments
  ( listPublicTournaments
  , selectPublic
  ) where

import Data.List (sortOn)

import Domain.Tournament
  (Tournament(..), TournamentId(..), TournamentState(..), Visibility(..))
import Shell.Persistence.Port (TournamentRepository)
import qualified Shell.Persistence.Port as Repo

-- Pure selection: Public, past Draft, newest first, capped.
selectPublic :: Int -> [Tournament] -> [Tournament]
selectPublic limit ts =
  take limit
    (sortOn (negate . unTournamentId . tournamentId) (filter visible ts))
  where
    visible t = tournamentVisibility t == Public && tournamentState t /= Draft

listPublicTournaments :: TournamentRepository m => m [Tournament]
listPublicTournaments = selectPublic 50 <$> Repo.listAllTournaments