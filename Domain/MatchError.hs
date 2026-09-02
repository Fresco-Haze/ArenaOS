module Domain.MatchError
  ( MatchError(..)
  ) where

import Domain.Match (MatchStatus, MatchOutcome)
import Domain.Participant (Participant)

data MatchError
  = MatchNotScheduled MatchStatus
  | MatchNotInProgress MatchStatus
  | ParticipantNotInMatch Participant
  | OutcomeNotAdvanceable MatchOutcome
  deriving (Eq, Show)