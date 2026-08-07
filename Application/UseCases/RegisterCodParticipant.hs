module Application.UseCases.RegisterCodParticipant
  ( registerCodParticipant
  , RegisterCodParticipantError(..)
  ) where

import Domain.Participant (Participant(..))
import Domain.Tournament (TournamentId)
import Shell.Persistence.Port
  ( TournamentRepository, ParticipantRepository, RegistrationRepository, RegistrationId )
import Application.UseCases.RegisterParticipant
  ( registerParticipant, RegisterParticipantError )

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
  case participant of
    Individual _ -> pure (Left CodRequiresTeam)
    Squad _      -> either (Left . CodRegistrationError) Right
                      <$> registerParticipant tournamentId participant