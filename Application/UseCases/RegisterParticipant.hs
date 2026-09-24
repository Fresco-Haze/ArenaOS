module Application.UseCases.RegisterParticipant
  ( registerParticipant
  , RegisterParticipantError(..)
  , registerParticipantChecked
  , RegisterParticipantCheckedError(..)
  ) where

import Data.Bifunctor (first)

import Domain.Ids (UserId)
import Domain.Participant (Participant(..))
import Domain.Registration (registrationParticipant)
import Domain.Tournament
  (TournamentId, TournamentState(RegistrationOpen), tournamentMaxParticipants)
import Application.Internal.Authorization (AuthorizationError, requireTournamentOwner)
import Application.Internal.LifecycleTransition (requireTournamentState, LifecycleError)
import Engine.TournamentValidation (ParticipantValidationError, validateParticipant)
import Shell.Persistence.Port
  ( TournamentRepository
  , ParticipantRepository
  , RegistrationRepository
  , RegistrationId
  , Transactional(..)
  , NewRegistration(..)
  )
import qualified Shell.Persistence.Port as Repo

-- ===== Original, unchanged =====

data RegisterParticipantError
  = RegistrationLifecycleError LifecycleError
  | RegistrationCapacityReached
  deriving (Eq, Show)

registerParticipant
  :: (TournamentRepository m, ParticipantRepository m, RegistrationRepository m)
  => TournamentId
  -> Participant
  -> m (Either RegisterParticipantError RegistrationId)
registerParticipant tournamentId participant = do
  tournament <- Repo.getTournament tournamentId
  case requireTournamentState RegistrationOpen tournament of
    Left lifecycleErr -> pure (Left (RegistrationLifecycleError lifecycleErr))
    Right () -> do
      registrations <- Repo.listRegistrations tournamentId
      if length registrations >= tournamentMaxParticipants tournament
        then pure (Left RegistrationCapacityReached)
        else do
          participantId <- Repo.resolveParticipant participant
          let newRegistration = NewRegistration
                { newRegistrationTournament  = tournamentId
                , newRegistrationParticipant = participantId
                }
          Right <$> Repo.createRegistration newRegistration

-- ===== Checked version (used by the API) =====

data RegisterParticipantCheckedError
  = Unauthorized AuthorizationError
  | InvalidParticipant ParticipantValidationError
  | InvalidLifecycle LifecycleError
  | AlreadyRegistered
  | CapacityReached
  deriving (Eq, Show)

registerParticipantChecked
  :: ( TournamentRepository m, ParticipantRepository m
     , RegistrationRepository m, Transactional m )
  => UserId
  -> TournamentId
  -> Participant
  -> m (Either RegisterParticipantCheckedError RegistrationId)
registerParticipantChecked caller tid participant =
  withTxEither $ do
    tournament <- Repo.getTournament tid
    case preChecks tournament of
      Left err -> pure (Left err)
      Right () -> do
        regs <- Repo.listRegistrations tid
        if participant `elem` map registrationParticipant regs
          then pure (Left AlreadyRegistered)
          else if length regs >= tournamentMaxParticipants tournament
            then pure (Left CapacityReached)
            else do
              case participant of
                Individual p -> Repo.savePlayer p
                Squad _      -> pure ()
              pid <- Repo.resolveParticipant participant
              Right <$> Repo.createRegistration NewRegistration
                { newRegistrationTournament  = tid
                , newRegistrationParticipant = pid
                }
  where
    preChecks t = do
      first Unauthorized (requireTournamentOwner caller t)
      first InvalidParticipant (validateParticipant participant)
      first InvalidLifecycle (requireTournamentState RegistrationOpen t)