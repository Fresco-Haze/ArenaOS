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
import Data.Time (UTCTime)

import Domain.Tournament
  ( Game, Tournament(..), TournamentId(..), TournamentName(..)
  , TournamentState(..), Visibility(..) )
import Shell.Persistence.Port (TournamentRepository)
import qualified Shell.Persistence.Port as Repo

-- v0.12: optional filters, applied BEFORE the cap so search can reach
-- tournaments older than the newest page.
-- pfUpcomingFrom = Just now keeps tournaments whose scheduled start is at or
-- after `now` (and not Completed/Cancelled), ordered soonest first.
data PublicFilter = PublicFilter
  { pfQuery        :: Maybe String   -- name contains, case-insensitive
  , pfGame         :: Maybe Game
  , pfLimit        :: Int
  , pfUpcomingFrom :: Maybe UTCTime
  } deriving (Eq, Show)

defaultPublicFilter :: PublicFilter
defaultPublicFilter = PublicFilter Nothing Nothing 50 Nothing

-- Pure selection: Public, past Draft, filtered, ordered, capped.
selectPublicFiltered :: PublicFilter -> [Tournament] -> [Tournament]
selectPublicFiltered f ts = take (pfLimit f) (ordered (filter keep ts))
  where
    keep t = tournamentVisibility t == Public
          && tournamentState t /= Draft
          && matchesGame t
          && matchesQuery t
          && matchesUpcoming t
    matchesGame t = maybe True (\g -> tournamentGame t == Just g) (pfGame f)
    matchesQuery t = case pfQuery f of
      Nothing -> True
      Just q  -> map toLower (trim q)
                   `isInfixOf` map toLower (unTournamentName (tournamentName t))
    matchesUpcoming t = case pfUpcomingFrom f of
      Nothing  -> True
      Just now -> maybe False (>= now) (tournamentStartTime t)
                    && tournamentState t `notElem` [Completed, Cancelled]
    ordered = case pfUpcomingFrom f of
      Nothing -> sortOn (negate . unTournamentId . tournamentId)
      Just _  -> sortOn (\t -> (tournamentStartTime t, unTournamentId (tournamentId t)))
    trim = dropWhileEnd isSpace . dropWhile isSpace

-- Unchanged behaviour: Public, past Draft, newest first, capped.
selectPublic :: Int -> [Tournament] -> [Tournament]
selectPublic limit = selectPublicFiltered (defaultPublicFilter { pfLimit = limit })

listPublicTournaments :: TournamentRepository m => m [Tournament]
listPublicTournaments = selectPublic 50 <$> Repo.listAllTournaments

listPublicTournamentsFiltered :: TournamentRepository m => PublicFilter -> m [Tournament]
listPublicTournamentsFiltered f = selectPublicFiltered f <$> Repo.listAllTournaments