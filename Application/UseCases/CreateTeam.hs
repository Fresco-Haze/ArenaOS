module Application.UseCases.CreateTeam
  ( createTeam
  , CreateTeamError(..)
  ) where

import Data.Char (isSpace)
import Data.List (nub)

import Domain.Participant (Team(..), TeamName(..), Player(..), PlayerName(..))
import Shell.Persistence.Port (ParticipantRepository(..))

data CreateTeamError
  = EmptyTeamName
  | EmptyPlayerName
  | DuplicateMemberNames
  | CaptainNotInMembers
  | TeamNameAlreadyExists TeamName
  deriving (Show, Eq)

isBlankPlayer :: Player -> Bool
isBlankPlayer (Player (PlayerName n)) = all isSpace n

createTeam :: ParticipantRepository m => Team -> m (Either CreateTeamError ())
createTeam team
  | all isSpace (unTeamName (teamName team)) =
      pure (Left EmptyTeamName)
  | any isBlankPlayer (teamCaptain team : teamMembers team) =
      pure (Left EmptyPlayerName)
  | length (nub (teamMembers team)) /= length (teamMembers team) =
      pure (Left DuplicateMemberNames)
  | teamCaptain team `notElem` teamMembers team =
      pure (Left CaptainNotInMembers)
  | otherwise = do
      exists <- teamExists (teamName team)
      if exists
        then pure (Left (TeamNameAlreadyExists (teamName team)))
        else do
          mapM_ savePlayer (teamMembers team)
          saveTeam team
          pure (Right ())