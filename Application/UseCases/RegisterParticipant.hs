module Application.UseCases.RegisterParticipant
  ( registerParticipant
  ) where

import Domain.Participant (Participant, ParticipantId)
import Domain.Tournament (TournamentId)
import Shell.Persistence.Port
  ( ParticipantRepository
  , RegistrationRepository
  , RegistrationId
  , NewRegistration(..)
  )
import qualified Shell.Persistence.Port as Repo

registerParticipant
  :: (ParticipantRepository m, RegistrationRepository m)
  => TournamentId
  -> Participant
  -> m RegistrationId
registerParticipant tournamentId participant = do
  participantId <- Repo.resolveParticipant participant
  let newRegistration = NewRegistration
        { newRegistrationTournament  = tournamentId
        , newRegistrationParticipant = participantId
        }
  Repo.createRegistration newRegistration