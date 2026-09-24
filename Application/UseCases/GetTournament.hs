module Application.UseCases.GetTournament
  ( getTournament
  , GetTournamentError(..)
  , TournamentView(..)
  ) where

import Data.Bifunctor (first)

import Domain.Ids (UserId)
import Domain.Participant (Participant)
import Domain.Registration (Registration(..))
import Domain.Tournament (Tournament(..), TournamentId)

import Shell.Persistence.Port (TournamentRepository, RegistrationRepository)
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization (AuthorizationError, requireVisibleToViewer)

data GetTournamentError
  = Unauthorized AuthorizationError
  deriving (Eq, Show)

data TournamentView = TournamentView
  { tvTournament    :: Tournament
  , tvParticipants  :: [Participant]
  , tvViewerIsOwner :: Bool
  } deriving (Eq, Show)

getTournament
  :: (TournamentRepository m, RegistrationRepository m)
  => Maybe UserId
  -> TournamentId
  -> m (Either GetTournamentError TournamentView)
getTournament viewer tid = do
  tournament <- Repo.getTournament tid
  case first Unauthorized (requireVisibleToViewer viewer tournament) of
    Left err -> pure (Left err)
    Right () -> do
      regs <- Repo.listRegistrations tid
      pure (Right TournamentView
        { tvTournament    = tournament
        , tvParticipants  = map registrationParticipant regs
        , tvViewerIsOwner = viewer == Just (tournamentOwner tournament)
        })