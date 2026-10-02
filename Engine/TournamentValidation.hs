module Engine.TournamentValidation
  ( TournamentValidationError(..)
  , validateTournamentFields
  , ParticipantValidationError(..)
  , validateParticipant
  , validateThirdPlaceMatch
  , participantMatchesMode
  ) where

import Data.Char (isSpace)
import Domain.Participant
  (Participant(..), Player(..), PlayerName(..), Team(..), TeamName(..))
import Domain.Tournament (TournamentName(..), OrganizerName(..), TournamentFormat(..), ParticipantMode(..))

data TournamentValidationError
  = EmptyName
  | EmptyOrganizer
  | MaxParticipantsTooLow Int
  | ThirdPlaceMatchRequiresSingleElimination
  deriving (Eq, Show)

validateTournamentFields
  :: TournamentName -> OrganizerName -> Int
  -> Either TournamentValidationError ()
validateTournamentFields (TournamentName name) (OrganizerName org) maxP
  | isBlank name = Left EmptyName
  | isBlank org  = Left EmptyOrganizer
  | maxP < 2     = Left (MaxParticipantsTooLow maxP)
  | otherwise    = Right ()

validateThirdPlaceMatch
  :: TournamentFormat -> Bool -> Either TournamentValidationError ()
validateThirdPlaceMatch format thirdPlaceMatch
  | thirdPlaceMatch && format /= SingleElimination =
      Left ThirdPlaceMatchRequiresSingleElimination
  | otherwise = Right ()

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

participantMatchesMode :: ParticipantMode -> Participant -> Bool
participantMatchesMode IndividualOnly (Individual _) = True
participantMatchesMode SquadOnly      (Squad _)      = True
participantMatchesMode _              _              = False