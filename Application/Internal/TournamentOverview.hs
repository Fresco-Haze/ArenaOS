module Application.Internal.TournamentOverview
  ( TournamentOverview(..)
  , StateCounts(..)
  , buildTournamentOverview
  ) where

import Domain.Tournament (Tournament(..), TournamentState(..))

data StateCounts = StateCounts
  { countDraft              :: Int
  , countPublished          :: Int
  , countRegistrationOpen   :: Int
  , countRegistrationClosed :: Int
  , countInProgress         :: Int
  , countCompleted          :: Int
  , countCancelled          :: Int
  } deriving (Eq, Show)

data TournamentOverview = TournamentOverview
  { overviewCounts      :: StateCounts
  , overviewTournaments :: [Tournament]
  } deriving (Eq, Show)

buildTournamentOverview :: [Tournament] -> TournamentOverview
buildTournamentOverview tournaments = TournamentOverview
  { overviewCounts = StateCounts
      { countDraft              = count Draft
      , countPublished          = count Published
      , countRegistrationOpen   = count RegistrationOpen
      , countRegistrationClosed = count RegistrationClosed
      , countInProgress         = count InProgress
      , countCompleted          = count Completed
      , countCancelled          = count Cancelled
      }
  , overviewTournaments = tournaments
  }
  where
    count s = length (filter ((== s) . tournamentState) tournaments)