module Application.UseCases.ListMyTournaments
  ( listMyTournaments
  ) where

import Domain.Ids (UserId)
import Domain.Tournament (Tournament)
import Shell.Persistence.Port (TournamentRepository)
import qualified Shell.Persistence.Port as Repo

listMyTournaments :: TournamentRepository m => UserId -> m [Tournament]
listMyTournaments = Repo.listTournamentsByOwner