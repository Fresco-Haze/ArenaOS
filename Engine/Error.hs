
module Engine.Error
  ( EngineError(..)
  ) where

import Domain.Participant (Participant)

data EngineError
  = TooFewParticipants Int
  | DuplicateParticipant Participant
  | ParticipantModeMismatch Participant
  deriving (Eq, Show)