module Application.UseCases.RegisterParticipant
  ( registerParticipant
  , RegisterParticipantError(..)
  ) where

import Domain.Participant (Participant, ParticipantId)
import Domain.Tournament (TournamentId, TournamentState(RegistrationOpen), tournamentMaxParticipants)
import Application.Internal.LifecycleTransition (requireTournamentState, LifecycleError)
import Shell.Persistence.Port
  ( TournamentRepository
  , ParticipantRepository
  , RegistrationRepository
  , RegistrationId
  , NewRegistration(..)
  )
import qualified Shell.Persistence.Port as Repo

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