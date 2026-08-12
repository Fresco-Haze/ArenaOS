module Application.UseCases.RegisterTeamOnly
  ( registerTeamOnly
  , RegisterTeamOnlyError(..)
  ) where

import Domain.Participant (Participant(..))
import Domain.Tournament (TournamentId)
import Shell.Persistence.Port
  ( TournamentRepository, ParticipantRepository, RegistrationRepository, RegistrationId )

import Application.UseCases.RegisterParticipant
  ( registerParticipant, RegisterParticipantError )

data RegisterTeamOnlyError
  = RequiresTeam
  | RegistrationError RegisterParticipantError
  deriving (Eq, Show)

registerTeamOnly
  :: (TournamentRepository m, ParticipantRepository m, RegistrationRepository m)
  => TournamentId
  -> Participant
  -> m (Either RegisterTeamOnlyError RegistrationId)
registerTeamOnly tournamentId participant =
  case participant of
    Individual _ -> pure (Left RequiresTeam)
    Squad _      -> either (Left . RegistrationError) Right
                      <$> registerParticipant tournamentId participant