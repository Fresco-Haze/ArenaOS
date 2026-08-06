module Application.UseCases.GetOrganizerDashboard
    ( getOrganizerDashboard
    , GetOrganizerDashboardError(..)
    , OrganizerDashboard(..)
    , StateCounts(..)
    , buildDashboard
    ) where

import Control.Monad.IO.Class (MonadIO, liftIO)

import Domain.Tournament (Tournament(..), TournamentState(..))
import Domain.Ids (UserId)

import Shell.Persistence.Port (TournamentRepository, UserRepository)
import qualified Shell.Persistence.Port as Repo
import Shell.Auth.Session (loadSession, SessionError)

data StateCounts = StateCounts
    { countDraft              :: Int
    , countPublished          :: Int
    , countRegistrationOpen   :: Int
    , countRegistrationClosed :: Int
    , countInProgress         :: Int
    , countCompleted          :: Int
    , countCancelled          :: Int
    } deriving (Show, Eq)

data OrganizerDashboard = OrganizerDashboard
    { dashboardCounts      :: StateCounts
    , dashboardTournaments :: [Tournament]
    } deriving (Show, Eq)

data GetOrganizerDashboardError
    = SessionInvalid SessionError
    | SessionAbsent
    | SessionUserNotFound
    deriving (Eq, Show)

getOrganizerDashboard
    :: (MonadIO m, UserRepository m, TournamentRepository m)
    => m (Either GetOrganizerDashboardError OrganizerDashboard)
getOrganizerDashboard = do
    sessionResult <- liftIO loadSession
    case sessionResult of
        Left sessionErr -> pure (Left (SessionInvalid sessionErr))
        Right Nothing -> pure (Left SessionAbsent)
        Right (Just uid) -> do
            maybeUser <- Repo.findUserById uid
            case maybeUser of
                Nothing -> pure (Left SessionUserNotFound)
                Just _  -> do
                    tournaments <- Repo.listTournamentsByOwner uid
                    pure (Right (buildDashboard tournaments))

-- Pure aggregation, deliberately separated from the IO/repository shell
-- above so the counting logic itself is trivially testable without a
-- database.
buildDashboard :: [Tournament] -> OrganizerDashboard
buildDashboard tournaments = OrganizerDashboard
    { dashboardCounts = StateCounts
        { countDraft              = countState Draft
        , countPublished          = countState Published
        , countRegistrationOpen   = countState RegistrationOpen
        , countRegistrationClosed = countState RegistrationClosed
        , countInProgress         = countState InProgress
        , countCompleted          = countState Completed
        , countCancelled          = countState Cancelled
        }
    , dashboardTournaments = tournaments
    }
  where
    countState s = length (filter (\t -> tournamentState t == s) tournaments)