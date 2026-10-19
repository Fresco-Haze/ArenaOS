module Engine.TournamentValidation
  ( TournamentValidationError(..)
  , validateTournamentFields
  , validateTournamentName
  , validateMaxParticipants
  , ParticipantValidationError(..)
  , validateParticipant
  , validateThirdPlaceMatch
  , participantMatchesMode
  , DetailsValidationError(..)
  , validateDetails
  ) where

import Data.Char (isSpace)
import Data.List (dropWhileEnd)
import Data.Time (UTCTime(..))
import Domain.Participant
  (Participant(..), Player(..), PlayerName(..), Team(..), TeamName(..))
import Domain.Tournament (TournamentName(..), OrganizerName(..), TournamentFormat(..), ParticipantMode(..), TournamentDetails(..))

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

validateTournamentName :: TournamentName -> Either TournamentValidationError ()
validateTournamentName (TournamentName name)
  | isBlank name = Left EmptyName
  | otherwise    = Right ()

validateMaxParticipants :: Int -> Either TournamentValidationError ()
validateMaxParticipants maxP
  | maxP < 2  = Left (MaxParticipantsTooLow maxP)
  | otherwise = Right ()

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

-- v0.11: game is validated by its type; prize is trimmed and capped,
-- start time is truncated to whole seconds (storage precision).
data DetailsValidationError = PrizeTooLong Int
  deriving (Eq, Show)

maxPrizeLength :: Int
maxPrizeLength = 100

validateDetails :: TournamentDetails -> Either DetailsValidationError TournamentDetails
validateDetails d =
  case fmap trim (detailsPrize d) of
    Just p | length p > maxPrizeLength -> Left (PrizeTooLong (length p))
    mp -> Right d { detailsPrize = nonBlank mp
                  , detailsStartTime = truncSecs <$> detailsStartTime d }
  where
    trim = dropWhileEnd isSpace . dropWhile isSpace
    nonBlank (Just p) | not (null p) = Just p
    nonBlank _                       = Nothing
    truncSecs (UTCTime day t) = UTCTime day (fromIntegral (floor t :: Integer))