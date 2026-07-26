module Engine.Validation
  ( validateParticipants
  ) where

import Domain.Participant (Participant)
import Domain.Tournament  (Tournament)
import Engine.Error       (EngineError(..))

validateParticipants
  :: Tournament
  -> [Participant]
  -> Either EngineError [Participant]
validateParticipants _tournament participants
  | participantCount < 2 =
      Left (TooFewParticipants participantCount)
  | Just dup <- findDuplicate participants =
      Left (DuplicateParticipant dup)
  -- DI-05 cannot yet be implemented because Tournament currently
  -- carries no participant-mode information. See ADR-FUT tracking
  -- the ParticipantMode design gap.
  | otherwise =
      Right participants
  where
    participantCount = length participants

findDuplicate :: [Participant] -> Maybe Participant
findDuplicate = go []
  where
    go _ [] = Nothing
    go seen (p : ps)
      | p `elem` seen = Just p
      | otherwise     = go (p : seen) ps