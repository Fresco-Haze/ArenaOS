module Application.UseCases.ListPublicTournaments
  ( listPublicTournaments
  , selectPublic
  , selectPublicMatching
  , listPublicTournamentsPage
  , PublicFilter(..)
  , StatusFilter(..)
  , FeeFilter(..)
  , defaultPublicFilter
  , selectPublicFiltered
  , listPublicTournamentsFiltered
  ) where

import Data.Char (isSpace, toLower)
import Data.List (dropWhileEnd, isInfixOf, sortOn)
import Data.Time (UTCTime)

import Domain.Tournament
  ( Game, Tournament(..), TournamentFormat(..), TournamentId(..), TournamentName(..)
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
  , pfOffset       :: Int            -- skip this many matches (paging)
  , pfStatus       :: Maybe StatusFilter
  , pfFormat       :: Maybe TournamentFormat
  , pfFee          :: Maybe FeeFilter
  } deriving (Eq, Show)

-- v0.15: coarse status groups for the public list.
-- open = registration open, live = in progress or paused, finished = completed.
data StatusFilter = StatusOpen | StatusLive | StatusFinished
  deriving (Eq, Show)

-- v0.15: free = no entry fee or a fee of 0, paid = a fee above 0.
data FeeFilter = FeeFree | FeePaid
  deriving (Eq, Show)
defaultPublicFilter :: PublicFilter
defaultPublicFilter = PublicFilter Nothing Nothing 50 Nothing 0 Nothing Nothing Nothing

-- Pure selection: Public, past Draft, filtered, ordered, capped.
selectPublicFiltered :: PublicFilter -> [Tournament] -> [Tournament]
selectPublicFiltered f = take (pfLimit f) . drop (pfOffset f) . selectPublicMatching f

-- Every public tournament that passes the filters, in order, with no paging.
selectPublicMatching :: PublicFilter -> [Tournament] -> [Tournament]
selectPublicMatching f ts = ordered (filter keep ts)
  where
    keep t = tournamentVisibility t == Public
          && tournamentState t /= Draft
          && matchesGame t
          && matchesQuery t
          && matchesUpcoming t
          && matchesStatus t
          && matchesFormat t
          && matchesFee t
    matchesGame t = maybe True (\g -> tournamentGame t == Just g) (pfGame f)
    matchesQuery t = case pfQuery f of
      Nothing -> True
      Just q  -> map toLower (trim q)
                   `isInfixOf` map toLower (unTournamentName (tournamentName t))
    matchesUpcoming t = case pfUpcomingFrom f of
      Nothing  -> True
      Just now -> maybe False (>= now) (tournamentStartTime t)
                    && tournamentState t `notElem` [Completed, Cancelled]
    matchesStatus t = case pfStatus f of
      Nothing             -> True
      Just StatusOpen     -> tournamentState t == RegistrationOpen
      Just StatusLive     -> tournamentState t `elem` [InProgress, Paused]
      Just StatusFinished -> tournamentState t == Completed
    matchesFormat t = maybe True (== tournamentFormat t) (pfFormat f)
    matchesFee t = case pfFee f of
      Nothing      -> True
      Just FeeFree -> maybe True (<= 0) (tournamentEntryFee t)
      Just FeePaid -> maybe False (> 0) (tournamentEntryFee t)
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

-- One page of results plus how many tournaments match in total.
listPublicTournamentsPage :: TournamentRepository m => PublicFilter -> m ([Tournament], Int)
listPublicTournamentsPage f = do
  matching <- selectPublicMatching f <$> Repo.listAllTournaments
  pure (take (pfLimit f) (drop (pfOffset f) matching), length matching)