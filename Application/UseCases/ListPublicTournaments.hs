module Application.UseCases.ListPublicTournaments
  ( listPublicTournaments
  , selectPublic
  , PublicFilter(..)
  , defaultPublicFilter
  , selectPublicFiltered
  , listPublicTournamentsFiltered
  ) where

import Data.Char (isSpace, toLower)
import Data.List (dropWhileEnd, isInfixOf, sortOn)

import Domain.Tournament
  ( Game, Tournament(..), TournamentId(..), TournamentName(..)
  , TournamentState(..), Visibility(..) )
import Shell.Persistence.Port (TournamentRepository)
import qualified Shell.Persistence.Port as Repo

-- v0.12: optional filters, applied BEFORE the cap so search can reach
-- tournaments older than the newest page.
data PublicFilter = PublicFilter
  { pfQuery :: Maybe String   -- name contains, case-insensitive
  , pfGame  :: Maybe Game
  , pfLimit :: Int
  } deriving (Eq, Show)

defaultPublicFilter :: PublicFilter
defaultPublicFilter = PublicFilter Nothing Nothing 50

-- Pure selection: Public, past Draft, filtered, newest first, capped.
selectPublicFiltered :: PublicFilter -> [Tournament] -> [Tournament]
selectPublicFiltered f ts =
  take (pfLimit f)
    (sortOn (negate . unTournamentId . tournamentId) (filter keep ts))
  where
    keep t = tournamentVisibility t == Public
          && tournamentState t /= Draft
          && matchesGame t
          && matchesQuery t
    matchesGame t = maybe True (\g -> tournamentGame t == Just g) (pfGame f)
    matchesQuery t = case pfQuery f of
      Nothing -> True
      Just q  -> map toLower (trim q)
                   `isInfixOf` map toLower (unTournamentName (tournamentName t))
    trim = dropWhileEnd isSpace . dropWhile isSpace

-- Unchanged behaviour: Public, past Draft, newest first, capped.
selectPublic :: Int -> [Tournament] -> [Tournament]
selectPublic limit = selectPublicFiltered (defaultPublicFilter { pfLimit = limit })

listPublicTournaments :: TournamentRepository m => m [Tournament]
listPublicTournaments = selectPublic 50 <$> Repo.listAllTournaments

listPublicTournamentsFiltered :: TournamentRepository m => PublicFilter -> m [Tournament]
listPublicTournamentsFiltered f = selectPublicFiltered f <$> Repo.listAllTournaments