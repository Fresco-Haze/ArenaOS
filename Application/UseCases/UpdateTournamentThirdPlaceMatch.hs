module Application.UseCases.UpdateTournamentThirdPlaceMatch
    ( updateTournamentThirdPlaceMatch
    , UpdateTournamentThirdPlaceMatchError(..)
    ) where

import Domain.Tournament (TournamentId, TournamentState(InProgress, Completed, Cancelled), tournamentFormat, tournamentBracket)
import Domain.TournamentHistory (TournamentHistoryEvent(ConfigurationChanged), ChangedField(FieldThirdPlaceMatch))
import Domain.Ids (UserId)

import Shell.Persistence.Port (TournamentRepository, TournamentHistoryRepository, Transactional(..))
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization (AuthorizationError, requireTournamentOwner)
import Application.Internal.LifecycleTransition (LifecycleError, requireTournamentStateNotIn)
import Engine.TournamentValidation (TournamentValidationError, validateThirdPlaceMatch)

data UpdateTournamentThirdPlaceMatchError
    = Unauthorized AuthorizationError
    | InvalidLifecycle LifecycleError
    | InvalidTournament TournamentValidationError
    | BracketAlreadyGenerated
    deriving (Eq, Show)

updateTournamentThirdPlaceMatch
    :: (TournamentRepository m, TournamentHistoryRepository m, Transactional m)
    => UserId
    -> TournamentId
    -> Bool
    -> m (Either UpdateTournamentThirdPlaceMatchError ())
updateTournamentThirdPlaceMatch currentUser tid newThirdPlaceMatch = do
    tournament <- Repo.getTournament tid
    case requireTournamentOwner currentUser tournament of
        Left err -> pure (Left (Unauthorized err))
        Right () ->
         case requireTournamentStateNotIn [InProgress, Completed, Cancelled] tournament of
             Left err -> pure (Left (InvalidLifecycle err))
             Right () ->
                 case tournamentBracket tournament of
                     Just _  -> pure (Left BracketAlreadyGenerated)
                     Nothing ->
                         case validateThirdPlaceMatch (tournamentFormat tournament) newThirdPlaceMatch of
                             Left err -> pure (Left (InvalidTournament err))
                             Right () -> do
                                  withTxN $ do
                                      Repo.updateTournamentThirdPlaceMatch tid newThirdPlaceMatch
                                      Repo.recordHistoryEvent tid (ConfigurationChanged FieldThirdPlaceMatch)
                                  pure (Right ())