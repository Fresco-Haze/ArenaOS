module Application.UseCases.UpdateTournamentDetails
    ( updateTournamentDetails
    , UpdateTournamentDetailsError(..)
    ) where

import Domain.Tournament
    ( Tournament(..), TournamentId, TournamentDetails(..)
    , TournamentState(InProgress, Completed, Cancelled) )
import Domain.TournamentHistory (TournamentHistoryEvent(ConfigurationChanged), ChangedField(..))
import Domain.Ids (UserId)

import Shell.Persistence.Port (TournamentRepository, TournamentHistoryRepository, Transactional(..))
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization (AuthorizationError, requireTournamentOwner)
import Application.Internal.LifecycleTransition (LifecycleError, requireTournamentStateNotIn)
import Engine.TournamentValidation (DetailsValidationError, validateDetails)

data UpdateTournamentDetailsError
    = Unauthorized AuthorizationError
    | InvalidLifecycle LifecycleError
    | InvalidDetails DetailsValidationError
    deriving (Eq, Show)

-- Replaces game, start time and prize (Nothing clears a field).
updateTournamentDetails
    :: (TournamentRepository m, TournamentHistoryRepository m, Transactional m)
    => UserId
    -> TournamentId
    -> TournamentDetails
    -> m (Either UpdateTournamentDetailsError ())
updateTournamentDetails currentUser tid new = do
    tournament <- Repo.getTournament tid
    case requireTournamentOwner currentUser tournament of
        Left err -> pure (Left (Unauthorized err))
        Right () ->
            case requireTournamentStateNotIn [InProgress, Completed, Cancelled] tournament of
                Left err -> pure (Left (InvalidLifecycle err))
                Right () -> case validateDetails new of
                    Left err -> pure (Left (InvalidDetails err))
                    Right d -> do
                        let changed =
                                [ FieldGame      | tournamentGame tournament      /= detailsGame d ]
                             ++ [ FieldStartTime | tournamentStartTime tournament /= detailsStartTime d ]
                             ++ [ FieldPrize     | tournamentPrize tournament     /= detailsPrize d ]
                             ++ [ FieldDescription | tournamentDescription tournament /= detailsDescription d ]
                        withTxN $ do
                            Repo.updateTournamentDetails tid d
                            mapM_ (Repo.recordHistoryEvent tid . ConfigurationChanged) changed
                        pure (Right ())