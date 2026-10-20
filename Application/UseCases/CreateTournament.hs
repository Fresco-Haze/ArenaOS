module Application.UseCases.CreateTournament
  ( createTournament
  , createTournamentChecked
  , CreateTournamentError(..)
  , createTournamentWithDetails
  , CreateWithDetailsError(..)
  ) where

import Control.Monad (when)
import Domain.Tournament (TournamentId, TournamentDetails, noDetails)
import Domain.TournamentHistory (TournamentHistoryEvent(TournamentCreated))
import Shell.Persistence.Port
  ( TournamentRepository
  , TournamentHistoryRepository
  , Transactional(..)
  , NewTournament(..)
  )
import qualified Shell.Persistence.Port as Repo
import Engine.TournamentValidation
  (TournamentValidationError, validateTournamentFields, validateThirdPlaceMatch, DetailsValidationError, validateDetails)

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
    Right () -> case validateThirdPlaceMatch (newTournamentFormat nt) (newTournamentThirdPlaceMatch nt) of
            Left err -> pure (Left (InvalidTournament err))
            Right () -> Right <$> createTournament nt

data CreateWithDetailsError
  = CreateInvalid TournamentValidationError
  | CreateInvalidDetails DetailsValidationError
  deriving (Eq, Show)

-- v0.12: create with optional game / start time / prize, one transaction.
createTournamentWithDetails
  :: (TournamentRepository m, TournamentHistoryRepository m, Transactional m)
  => NewTournament
  -> TournamentDetails
  -> m (Either CreateWithDetailsError TournamentId)
createTournamentWithDetails nt details =
  case validateTournamentFields
         (newTournamentName nt)
         (newTournamentOrganizer nt)
         (newTournamentMaxParticipants nt) of
    Left err -> pure (Left (CreateInvalid err))
    Right () -> case validateThirdPlaceMatch (newTournamentFormat nt) (newTournamentThirdPlaceMatch nt) of
      Left err -> pure (Left (CreateInvalid err))
      Right () -> case validateDetails details of
        Left err -> pure (Left (CreateInvalidDetails err))
        Right d -> fmap Right $ withTxN $ do
          tid <- Repo.createTournament nt
          when (d /= noDetails) (Repo.updateTournamentDetails tid d)
          Repo.recordHistoryEvent tid TournamentCreated
          pure tid