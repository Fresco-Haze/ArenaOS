module Application.UseCases.TeamProfile
  ( TeamProfileError(..)
  , TeamProfileView(..)
  , updateTeamProfile
  , readTeamProfile
  , teamRegions
  ) where

import Data.Char (isAlphaNum, isSpace, toUpper)
import Data.List (dropWhileEnd)

import Domain.Ids (UserId)
import Domain.Participant (TeamName)
import Domain.TeamProfile (Recruitment(..), TeamProfile(..))
import Shell.Persistence.Port (ParticipantRepository, TeamProfileRepository)
import qualified Shell.Persistence.Port as Repo

data TeamProfileError
  = ProfileNotOwner
  | ProfileInvalid
  deriving (Eq, Show)

-- the profile, wins and losses
data TeamProfileView = TeamProfileView
  { tpvProfile :: TeamProfile
  , tpvWins    :: Int
  , tpvLosses  :: Int
  } deriving (Eq, Show)

teamRegions :: [String]
teamRegions =
  [ "NA East", "NA West", "EU West", "EU Nordic"
  , "South America", "Oceania", "Southeast Asia", "Middle East" ]

validate :: TeamProfile -> Maybe TeamProfile
validate (TeamProfile tag game region rec)
  | not (okTag t)                          = Nothing
  | length g > 40                          = Nothing
  | region `notElem` ("" : teamRegions)    = Nothing
  | otherwise                              = Just (TeamProfile t g region rec)
  where
    t = map toUpper tag
    g = trim game
    trim = dropWhileEnd isSpace . dropWhile isSpace
    okTag s = null s || (length s >= 3 && length s <= 4 && all isAlphaNum s)

updateTeamProfile
  :: (ParticipantRepository m, TeamProfileRepository m)
  => UserId -> TeamName -> TeamProfile -> m (Either TeamProfileError ())
updateTeamProfile caller tn p = do
  owner <- Repo.getTeamOwner tn
  if owner /= Just caller
    then pure (Left ProfileNotOwner)
    else case validate p of
      Nothing    -> pure (Left ProfileInvalid)
      Just clean -> do
        Repo.setTeamProfile tn clean
        pure (Right ())

readTeamProfile :: TeamProfileRepository m => TeamName -> m TeamProfileView
readTeamProfile tn = do
  mp <- Repo.getTeamProfile tn
  (w, l) <- Repo.getTeamRecord tn
  pure (TeamProfileView (maybe (TeamProfile "" "" "" InviteOnly) id mp) w l)