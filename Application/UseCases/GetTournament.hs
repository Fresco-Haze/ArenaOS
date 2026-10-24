module Application.UseCases.GetTournament
  ( getTournament
  , GetTournamentError(..)
  , TournamentView(..)
  ) where

import Data.Bifunctor (first)
import Data.Maybe (isJust)

import Domain.Ids (UserId)
import Domain.Participant (Participant)
import Domain.Registration (Registration(..))
import Domain.Tournament (Tournament(..), TournamentId)

import Shell.Persistence.Port (TournamentRepository, RegistrationRepository, JoinRequestRepository)
import Domain.JoinRequest (JoinRequestStatus)
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization (AuthorizationError, requireVisibleToViewer)

data GetTournamentError
  = Unauthorized AuthorizationError
  deriving (Eq, Show)

data TournamentView = TournamentView
  { tvTournament    :: Tournament
  , tvParticipants  :: [Participant]
  , tvViewerIsOwner :: Bool
  , tvViewerIsRegistered :: Bool
  , tvViewerRequestStatus :: Maybe JoinRequestStatus
  } deriving (Eq, Show)

getTournament
  :: (TournamentRepository m, RegistrationRepository m, JoinRequestRepository m)
  => Maybe UserId
  -> TournamentId
  -> m (Either GetTournamentError TournamentView)
getTournament viewer tid = do
  tournament <- Repo.getTournament tid
  case first Unauthorized (requireVisibleToViewer viewer tournament) of
    Left err -> pure (Left err)
    Right () -> do
      regs <- Repo.listRegistrations tid
      registered <- maybe (pure False) (\u -> isJust <$> Repo.findUserRegistration tid u) viewer
      reqStatus <- maybe (pure Nothing) (\u -> Repo.getJoinRequest tid u) viewer
      pure (Right TournamentView
        { tvTournament    = tournament
        , tvParticipants  = map registrationParticipant regs
        , tvViewerIsOwner = viewer == Just (tournamentOwner tournament)
        , tvViewerIsRegistered = registered
        , tvViewerRequestStatus = reqStatus
        })