-- Application.UseCases.Lobby
-- Lobby (battle royale style) tournaments: create, start, record rounds,
-- complete. Every action is owner-only and only works on a lobby.
-- loadLobbyStandings has NO permission check: a route that exposes it must
-- check visibility first.
module Application.UseCases.Lobby
  ( createLobbyTournament
  , CreateLobbyError(..)
  , startLobby
  , recordLobbyRound
  , completeLobby
  , loadLobbyStandings
  , LobbyActionError(..)
  ) where

import Control.Monad (when)

import Domain.Ids (UserId)
import Domain.Lobby (GameEntry(..), LobbySettings(..))
import Domain.Notification (NotificationKind(NoteTournamentStarted))
import Domain.Participant (ParticipantId)
import Domain.Registration (Registration(..))
import Domain.Tournament
  ( Tournament(..), TournamentId, TournamentDetails, TournamentFormat(..)
  , TournamentKind(..), TournamentState(..), noDetails )
import Domain.TournamentError (TournamentError(..))
import Domain.TournamentHistory
  (TournamentHistoryEvent(TournamentCreated, TournamentStarted, TournamentCompleted))

import Shell.Persistence.Port
  ( TournamentRepository, TournamentHistoryRepository, RegistrationRepository
  , NotificationRepository, ParticipantRepository, LobbyRepository
  , Transactional(..), NewTournament(..) )
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization (AuthorizationError, requireTournamentOwner)
import Application.Internal.LifecycleTransition
  (LifecycleError, requireTournamentState, requireOperationallyActive)
import Engine.TournamentValidation
  ( TournamentValidationError, DetailsValidationError
  , validateTournamentFields, validateDetails )
import qualified Engine.Lobby as EL

data CreateLobbyError
  = LobbyCreateInvalid TournamentValidationError
  | LobbyCreateInvalidDetails DetailsValidationError
  | LobbyCreateBadSettings
  deriving (Eq, Show)

-- Kill points 0..1000; 1..100 placement values, each 0..1000.
settingsOk :: LobbySettings -> Bool
settingsOk (LobbySettings kp ps) =
  kp >= 0 && kp <= 1000 && not (null ps) && length ps <= 100
    && all (\p -> p >= 0 && p <= 1000) ps

-- A lobby has no bracket, so it stores a placeholder format (the column is
-- required) and never a third-place match.
createLobbyTournament
  :: (TournamentRepository m, TournamentHistoryRepository m, LobbyRepository m, Transactional m)
  => NewTournament
  -> TournamentDetails
  -> LobbySettings
  -> m (Either CreateLobbyError TournamentId)
createLobbyTournament nt0 details settings =
  case validateTournamentFields
         (newTournamentName nt)
         (newTournamentOrganizer nt)
         (newTournamentMaxParticipants nt) of
    Left err -> pure (Left (LobbyCreateInvalid err))
    Right ()
      | not (settingsOk settings) -> pure (Left LobbyCreateBadSettings)
      | otherwise -> case validateDetails details of
          Left err -> pure (Left (LobbyCreateInvalidDetails err))
          Right d -> fmap Right $ withTxN $ do
            tid <- Repo.createTournament nt
            Repo.setTournamentKind tid LobbyKind
            Repo.saveLobbySettings tid settings
            when (d /= noDetails) (Repo.updateTournamentDetails tid d)
            Repo.recordHistoryEvent tid TournamentCreated
            pure tid
  where
    nt = nt0 { newTournamentFormat = SingleElimination, newTournamentThirdPlaceMatch = False }

data LobbyActionError
  = LobbyUnauthorized AuthorizationError
  | LobbyInvalidLifecycle LifecycleError
  | NotALobby
  | LobbyNeedsTwoParticipants
  | LobbyInvalidResults EL.LobbyError
  | LobbyRoundNotFound Int
  | LobbyCompleteInvalid TournamentError
  deriving (Eq, Show)

-- Owner first, then "is it a lobby".
loadOwnedLobby
  :: TournamentRepository m
  => UserId -> TournamentId -> m (Either LobbyActionError Tournament)
loadOwnedLobby uid tid = do
  t <- Repo.getTournament tid
  pure $ case requireTournamentOwner uid t of
    Left err -> Left (LobbyUnauthorized err)
    Right ()
      | tournamentKind t /= LobbyKind -> Left NotALobby
      | otherwise                     -> Right t

registeredParticipantIds
  :: (RegistrationRepository m, ParticipantRepository m)
  => TournamentId -> m [ParticipantId]
registeredParticipantIds tid = do
  regs <- Repo.listRegistrations tid
  mapM (Repo.resolveParticipant . registrationParticipant) regs

-- RegistrationClosed -> InProgress, with at least two registered participants.
startLobby
  :: ( TournamentRepository m, TournamentHistoryRepository m, RegistrationRepository m
     , NotificationRepository m, Transactional m )
  => UserId -> TournamentId -> m (Either LobbyActionError ())
startLobby uid tid = do
  r <- loadOwnedLobby uid tid
  case r of
    Left e -> pure (Left e)
    Right t -> case requireTournamentState RegistrationClosed t of
      Left e -> pure (Left (LobbyInvalidLifecycle e))
      Right () -> do
        regs <- Repo.listRegistrations tid
        if length regs < 2
          then pure (Left LobbyNeedsTwoParticipants)
          else do
            withTxN $ do
              Repo.updateTournamentState tid InProgress
              Repo.recordHistoryEvent tid TournamentStarted
              uids <- Repo.listRegisteredUserIds tid
              mapM_ (\u -> Repo.addNotification u NoteTournamentStarted tid Nothing) uids
            pure (Right ())

-- Nothing adds the next round; Just n corrects round n. The results must cover
-- every registered participant exactly once. Returns the round number.
recordLobbyRound
  :: ( TournamentRepository m, RegistrationRepository m, ParticipantRepository m
     , LobbyRepository m, Transactional m )
  => UserId -> TournamentId -> Maybe Int -> [GameEntry ParticipantId]
  -> m (Either LobbyActionError Int)
recordLobbyRound uid tid mRound entries = do
  r <- loadOwnedLobby uid tid
  case r of
    Left e -> pure (Left e)
    Right t -> case requireOperationallyActive t of
      Left e -> pure (Left (LobbyInvalidLifecycle e))
      Right () -> do
        registered <- registeredParticipantIds tid
        case EL.validateGame registered entries of
          Left e -> pure (Left (LobbyInvalidResults e))
          Right () -> do
            existing <- fmap (map fst) (Repo.listLobbyRounds tid)
            case mRound of
              Just n | n `notElem` existing -> pure (Left (LobbyRoundNotFound n))
              _ -> fmap Right $ withTxN $ do
                n <- maybe (Repo.addLobbyRound tid) pure mRound
                Repo.saveLobbyRoundResults tid n entries
                pure n

-- Needs at least one round. Same rejections as completing a bracket tournament.
completeLobby
  :: (TournamentRepository m, TournamentHistoryRepository m, LobbyRepository m, Transactional m)
  => UserId -> TournamentId -> m (Either LobbyActionError Tournament)
completeLobby uid tid = do
  r <- loadOwnedLobby uid tid
  case r of
    Left e -> pure (Left e)
    Right t -> case tournamentState t of
      Completed -> pure (Left (LobbyCompleteInvalid TournamentAlreadyCompleted))
      Cancelled -> pure (Left (LobbyCompleteInvalid TournamentAlreadyCancelled))
      Paused    -> pure (Left (LobbyCompleteInvalid TournamentPaused))
      _ -> do
        rounds <- Repo.listLobbyRounds tid
        if null rounds
          then pure (Left (LobbyCompleteInvalid TournamentNotComplete))
          else do
            withTxN $ do
              Repo.updateTournamentState tid Completed
              Repo.recordHistoryEvent tid TournamentCompleted
            pure (Right (t { tournamentState = Completed }))

-- The table for a lobby, best first. No permission check (see the header).
loadLobbyStandings
  :: (RegistrationRepository m, ParticipantRepository m, LobbyRepository m)
  => TournamentId -> m [EL.LobbyStanding ParticipantId]
loadLobbyStandings tid = do
  settings <- Repo.getLobbySettings tid
  registered <- registeredParticipantIds tid
  rounds <- Repo.listLobbyRounds tid
  pure (EL.lobbyStandings settings registered (map snd rounds))