module Application.UseCases.CreateTournament
  ( createTournament
  ) where

import Domain.Tournament (TournamentId)
import Domain.TournamentHistory (TournamentHistoryEvent(TournamentCreated))
import Shell.Persistence.Port
  ( TournamentRepository
  , TournamentHistoryRepository
  , Transactional(..)
  , NewTournament
  )
import qualified Shell.Persistence.Port as Repo

createTournament
  :: (TournamentRepository m, TournamentHistoryRepository m, Transactional m)
  => NewTournament
  -> m TournamentId
createTournament newTournament = do
  withTxN $ do
    tid <- Repo.createTournament newTournament
    Repo.recordHistoryEvent tid TournamentCreated
    pure tid