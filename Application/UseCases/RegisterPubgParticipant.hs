module Application.UseCases.RegisterPubgParticipant
  ( registerPubgParticipant
  , RegisterPubgParticipantError(..)
  ) where

import Domain.Participant (Participant(..))
import Domain.Tournament (TournamentId)
import Shell.Persistence.Port
  ( TournamentRepository
  , ParticipantRepository
  , RegistrationRepository
  , RegistrationId
  )
import Application.UseCases.RegisterParticipant
  ( registerParticipant
  , RegisterParticipantError
  )

-- | FR-PUBGOPS-001: PUBG tournaments require team-based registration.
-- Deliberately mirrors RegisterCodParticipant's shape rather than sharing
-- a type with it -- v0.4 keeps CoD and PUBG as two independent concrete
-- cases so v0.5 has real evidence to decide whether they should ever be
-- unified. No roster-size, scoring, or eligibility rules are enforced
-- here; those are out of v0.4 scope by design (see FR-PUBGOPS-001 notes).
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
  case participant of
    Individual _ -> pure (Left PubgRequiresTeam)
    Squad _ ->
      either (Left . PubgRegistrationError) Right
        <$> registerParticipant tournamentId participant