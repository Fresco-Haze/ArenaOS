module Application.UseCases.RegisterPubgParticipant
  ( registerPubgParticipant
  , RegisterPubgParticipantError(..)
  ) where

import Domain.Participant (Participant)
import Domain.Tournament (TournamentId)
import Shell.Persistence.Port( TournamentRepository, ParticipantRepository, RegistrationRepository, RegistrationId)
import Application.UseCases.RegisterParticipant ( RegisterParticipantError )
import Application.UseCases.RegisterTeamOnly( registerTeamOnly, RegisterTeamOnlyError(..))

data RegisterPubgParticipantError
  = PubgRequiresTeam
  | PubgRegistrationError RegisterParticipantError
  deriving (Eq, Show)

registerPubgParticipant
  :: (TournamentRepository m, ParticipantRepository m, RegistrationRepository m)
  => TournamentId
  -> Participant
  -> m (Either RegisterPubgParticipantError RegistrationId)
registerPubgParticipant tournamentId participant =
  either (Left . translate) Right
    <$> registerTeamOnly tournamentId participant
  where
    translate RequiresTeam          = PubgRequiresTeam
    translate (RegistrationError e) = PubgRegistrationError e