module Application.UseCases.RegisterCodParticipant
  ( registerCodParticipant
  , RegisterCodParticipantError(..)
  ) where

import Domain.Participant (Participant)
import Domain.Tournament (TournamentId)

import Shell.Persistence.Port ( TournamentRepository , ParticipantRepository , RegistrationRepository, RegistrationId )

import Application.UseCases.RegisterParticipant( RegisterParticipantError )

import Application.UseCases.RegisterTeamOnly( registerTeamOnly, RegisterTeamOnlyError(..))

data RegisterCodParticipantError
  = CodRequiresTeam
  | CodRegistrationError RegisterParticipantError
  deriving (Eq, Show)

registerCodParticipant
  :: (TournamentRepository m, ParticipantRepository m, RegistrationRepository m)
  => TournamentId
  -> Participant
  -> m (Either RegisterCodParticipantError RegistrationId)
registerCodParticipant tournamentId participant =
  either (Left . translate) Right
    <$> registerTeamOnly tournamentId participant
  where
    translate RequiresTeam          = CodRequiresTeam
    translate (RegistrationError e) = CodRegistrationError e