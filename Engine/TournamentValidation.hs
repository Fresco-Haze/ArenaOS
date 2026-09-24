module Engine.TournamentValidation
  ( TournamentValidationError(..)
  , validateTournamentFields
  , ParticipantValidationError(..)
  , validateParticipant
  ) where

import Data.Char (isSpace)
import Domain.Participant
  (Participant(..), Player(..), PlayerName(..), Team(..), TeamName(..))
import Domain.Tournament (TournamentName(..), OrganizerName(..))

data TournamentValidationError
  = EmptyName
  | EmptyOrganizer
  | MaxParticipantsTooLow Int
  deriving (Eq, Show)

validateTournamentFields
  :: TournamentName -> OrganizerName -> Int
  -> Either TournamentValidationError ()
validateTournamentFields (TournamentName name) (OrganizerName org) maxP
  | isBlank name = Left EmptyName
  | isBlank org  = Left EmptyOrganizer
  | maxP < 2     = Left (MaxParticipantsTooLow maxP)
  | otherwise    = Right ()

data ParticipantValidationError
  = BlankPlayerName
  | BlankTeamName
  deriving (Eq, Show)

validateParticipant :: Participant -> Either ParticipantValidationError ()
validateParticipant (Individual (Player (PlayerName n)))
  | isBlank n = Left BlankPlayerName
validateParticipant (Squad t)
  | isBlank (unTeamName (teamName t)) = Left BlankTeamName
validateParticipant _ = Right ()

isBlank :: String -> Bool
isBlank = all isSpace