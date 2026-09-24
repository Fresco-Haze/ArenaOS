module Application.UseCases.CreateTournament
  ( createTournament
  , createTournamentChecked
  , CreateTournamentError(..)
  ) where

import Domain.Tournament (TournamentId)
import Domain.TournamentHistory (TournamentHistoryEvent(TournamentCreated))
import Shell.Persistence.Port
  ( TournamentRepository
  , TournamentHistoryRepository
  , Transactional(..)
  , NewTournament(..)
  )
import qualified Shell.Persistence.Port as Repo
import Engine.TournamentValidation
  (TournamentValidationError, validateTournamentFields)

data CreateTournamentError
  = InvalidTournament TournamentValidationError
  deriving (Eq, Show)

createTournament
  :: (TournamentRepository m, TournamentHistoryRepository m, Transactional m)
  => NewTournament
  -> m TournamentId
createTournament newTournament = do
  withTxN $ do
    tid <- Repo.createTournament newTournament
    Repo.recordHistoryEvent tid TournamentCreated
    pure tid

createTournamentChecked
  :: (TournamentRepository m, TournamentHistoryRepository m, Transactional m)
  => NewTournament
  -> m (Either CreateTournamentError TournamentId)
createTournamentChecked nt =
  case validateTournamentFields
         (newTournamentName nt)
         (newTournamentOrganizer nt)
         (newTournamentMaxParticipants nt) of
    Left err -> pure (Left (InvalidTournament err))
    Right () -> Right <$> createTournament nt