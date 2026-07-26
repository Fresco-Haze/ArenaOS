module Application.UseCases.CreateTournament
  ( createTournament
  ) where

import Domain.Tournament (TournamentId)
import Shell.Persistence.Port
  ( TournamentRepository
  , NewTournament
  )
import qualified Shell.Persistence.Port as Repo

createTournament :: TournamentRepository m => NewTournament -> m TournamentId
createTournament = Repo.createTournament