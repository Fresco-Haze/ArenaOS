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

-- v0.12: game is validated by its type; the prize is a whole number of KSh
-- (0 means no prize); the description is trimmed and capped (blank means none);
-- the start time is truncated to whole seconds.
data DetailsValidationError
  = PrizeOutOfRange Int
  | DescriptionTooLong Int
  | DeadlineAfterStart
  deriving (Eq, Show)

maxPrizeKes :: Int
maxPrizeKes = 1000000000

maxDescriptionLength :: Int
maxDescriptionLength = 500

validateDetails :: TournamentDetails -> Either DetailsValidationError TournamentDetails
validateDetails d =
  case (detailsPrize d, trimmed) of
    (Just n, _) | n < 0 || n > maxPrizeKes -> Left (PrizeOutOfRange n)
    (_, Just s) | length s > maxDescriptionLength -> Left (DescriptionTooLong (length s))
    _ | deadlineAfterStart -> Left DeadlineAfterStart
    _ -> Right d { detailsPrize = detailsPrize d >>= nonZero
                 , detailsDescription = trimmed >>= nonBlank
                 , detailsStartTime = truncSecs <$> detailsStartTime d
                 , detailsRegistrationDeadline = truncSecs <$> detailsRegistrationDeadline d }
  where
    trimmed = trim <$> detailsDescription d
    deadlineAfterStart = case (detailsRegistrationDeadline d, detailsStartTime d) of
      (Just r, Just s) -> r > s
      _ -> False
    trim = dropWhileEnd isSpace . dropWhile isSpace
    nonZero n = if n == 0 then Nothing else Just n
    nonBlank s = if null s then Nothing else Just s
    truncSecs (UTCTime day t) = UTCTime day (fromIntegral (floor t :: Integer))