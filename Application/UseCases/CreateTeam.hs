module Application.UseCases.CreateTeam
  ( createTeam
  , CreateTeamError(..)
  ) where

import Domain.Participant (Team(..), TeamName)
import Shell.Persistence.Port (ParticipantRepository(..))

data CreateTeamError
  = CaptainNotInMembers
  | TeamNameAlreadyExists TeamName
  deriving (Show, Eq)

createTeam :: ParticipantRepository m => Team -> m (Either CreateTeamError ())
createTeam team
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