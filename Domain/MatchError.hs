module Domain.MatchError
  ( MatchError(..)
  ) where

import Domain.Match (MatchStatus)
import Domain.Participant (Participant)

data MatchError
  = MatchNotScheduled MatchStatus
  | MatchNotInProgress MatchStatus
  | ParticipantNotInMatch Participant
  deriving (Eq, Show)