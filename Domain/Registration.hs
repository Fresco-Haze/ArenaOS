-- Domain.Registration
-- Pure data types only, zero logic (Architecture.md: Domain layer).
-- Transcribed from Document 3 (Domain Model, Core Types).
module Domain.Registration
    ( RegistrationId(..)
    , RegistrationStatus(..)
    , Registration(..)
    ) where

import Domain.Tournament (TournamentId)
import Domain.Participant (Participant)

newtype RegistrationId = RegistrationId {unRegistrationId :: Int} deriving (Show, Eq)

-- INV-2: extensible on purpose. v0.1/v0.2 only ever produce Confirmed.
data RegistrationStatus = Confirmed deriving (Show, Eq)

data Registration = Registration
    { registrationId :: RegistrationId
    , registrationTournament :: TournamentId
    , registrationParticipant :: Participant
    , registrationStatus :: RegistrationStatus
    } deriving (Show, Eq)