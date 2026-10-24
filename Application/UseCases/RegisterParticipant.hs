module Application.UseCases.RegisterParticipant
  ( registerParticipant
  , RegisterParticipantError(..)
  , registerParticipantChecked
  , RegisterParticipantCheckedError(..)
  , joinTournament
  , JoinTournamentError(..)
  , withdrawFromTournament
  , WithdrawError(..)
  , removeParticipant
  , RemoveError(..)
  , listMyRegistrations
  ) where

import Data.Bifunctor (first)
import qualified Data.Text as T
import Domain.User (Username(..), User(username))

import Domain.Ids (UserId)
import Domain.Participant (Participant(..), Player(..), PlayerName(..))
import Domain.Registration (registrationParticipant, registrationId)
import Domain.Tournament
  (Tournament, TournamentId, TournamentState(RegistrationOpen), tournamentMaxParticipants, tournamentParticipantMode, ParticipantMode(..))
import Application.Internal.Authorization (AuthorizationError, requireTournamentOwner, requireVisibleToViewer)
import Application.Internal.LifecycleTransition (requireTournamentState, LifecycleError)
import Engine.TournamentValidation (ParticipantValidationError, validateParticipant, participantMatchesMode)
import Shell.Persistence.Port
  ( TournamentRepository
  , ParticipantRepository
  , RegistrationRepository
  , RegistrationId
  , Transactional(..)
  , NewRegistration(..)
  , UserRepository
  )
import qualified Shell.Persistence.Port as Repo
import Control.Monad (unless)

-- ===== Original, unchanged =====

data RegisterParticipantError
  = RegistrationLifecycleError LifecycleError
  | RegistrationCapacityReached
  deriving (Eq, Show)

registerParticipant
  :: (TournamentRepository m, ParticipantRepository m, RegistrationRepository m)
  => TournamentId
  -> Participant
  -> m (Either RegisterParticipantError RegistrationId)
registerParticipant tournamentId participant = do
  tournament <- Repo.getTournament tournamentId
  case requireTournamentState RegistrationOpen tournament of
    Left lifecycleErr -> pure (Left (RegistrationLifecycleError lifecycleErr))
    Right () -> do
      registrations <- Repo.listRegistrations tournamentId
      if length registrations >= tournamentMaxParticipants tournament
        then pure (Left RegistrationCapacityReached)
        else do
          participantId <- Repo.resolveParticipant participant
          let newRegistration = NewRegistration
                { newRegistrationTournament  = tournamentId
                , newRegistrationParticipant = participantId
                }
          Right <$> Repo.createRegistration newRegistration

-- ===== Checked version (used by the API) =====

data RegisterParticipantCheckedError
  = Unauthorized AuthorizationError
  | InvalidParticipant ParticipantValidationError
  | InvalidLifecycle LifecycleError
  | AlreadyRegistered
  | CapacityReached
  | ParticipantKindNotAllowed ParticipantMode
  deriving (Eq, Show)

registerParticipantChecked
  :: ( TournamentRepository m, ParticipantRepository m
     , RegistrationRepository m, Transactional m )
  => UserId
  -> TournamentId
  -> Participant
  -> m (Either RegisterParticipantCheckedError RegistrationId)
registerParticipantChecked caller tid participant =
  withTxEither $ do
    tournament <- Repo.getTournament tid
    case preChecks tournament of
      Left err -> pure (Left err)
      Right () -> do
        regs <- Repo.listRegistrations tid
        if participant `elem` map registrationParticipant regs
          then pure (Left AlreadyRegistered)
          else if length regs >= tournamentMaxParticipants tournament
            then pure (Left CapacityReached)
            else do
              case participant of
                Individual p -> Repo.savePlayer p
                Squad _      -> pure ()
              pid <- Repo.resolveParticipant participant
              Right <$> Repo.createRegistration NewRegistration
                { newRegistrationTournament  = tid
                , newRegistrationParticipant = pid
                }
  where
    preChecks t = do
      first Unauthorized (requireTournamentOwner caller t)
      first InvalidParticipant (validateParticipant participant)
      first InvalidLifecycle (requireTournamentState RegistrationOpen t)

      unless (participantMatchesMode (tournamentParticipantMode t) participant)
        (Left (ParticipantKindNotAllowed (tournamentParticipantMode t)))

-- ===== Self-registration (v0.12) =====
-- The registration is linked to the account; the player name is the username.

data JoinTournamentError
  = JoinNotVisible AuthorizationError
  | JoinLifecycle LifecycleError
  | JoinSquadOnly
  | JoinAlreadyJoined
  | JoinNameTaken
  | JoinFull
  | JoinAccountMissing
  deriving (Eq, Show)

joinTournament
  :: ( TournamentRepository m, ParticipantRepository m
     , RegistrationRepository m, UserRepository m, Transactional m )
  => UserId
  -> TournamentId
  -> m (Either JoinTournamentError RegistrationId)
joinTournament caller tid =
  withTxEither $ do
    tournament <- Repo.getTournament tid
    case preChecks tournament of
      Left err -> pure (Left err)
      Right () -> do
        mUser <- Repo.findUserById caller
        case mUser of
          Nothing -> pure (Left JoinAccountMissing)
          Just u -> do
            existing <- Repo.findUserRegistration tid caller
            regs <- Repo.listRegistrations tid
            let player = Player (PlayerName (T.unpack (unUsername (username u))))
                participant = Individual player
            case existing of
              Just _ -> pure (Left JoinAlreadyJoined)
              Nothing
                | participant `elem` map registrationParticipant regs ->
                    pure (Left JoinNameTaken)
                | length regs >= tournamentMaxParticipants tournament ->
                    pure (Left JoinFull)
                | otherwise -> do
                    Repo.savePlayer player
                    pid <- Repo.resolveParticipant participant
                    Right <$> Repo.createUserRegistration caller NewRegistration
                      { newRegistrationTournament  = tid
                      , newRegistrationParticipant = pid
                      }
  where
    preChecks t = do
      first JoinNotVisible (requireVisibleToViewer (Just caller) t)
      first JoinLifecycle (requireTournamentState RegistrationOpen t)
      unless (tournamentParticipantMode t == IndividualOnly) (Left JoinSquadOnly)

data WithdrawError
  = WithdrawLifecycle LifecycleError
  | WithdrawNotRegistered
  deriving (Eq, Show)

withdrawFromTournament
  :: (TournamentRepository m, RegistrationRepository m, Transactional m)
  => UserId
  -> TournamentId
  -> m (Either WithdrawError ())
withdrawFromTournament caller tid =
  withTxEither $ do
    tournament <- Repo.getTournament tid
    case requireTournamentState RegistrationOpen tournament of
      Left e -> pure (Left (WithdrawLifecycle e))
      Right () -> do
        mReg <- Repo.findUserRegistration tid caller
        case mReg of
          Nothing  -> pure (Left WithdrawNotRegistered)
          Just rid -> do
            Repo.deleteRegistration rid
            pure (Right ())

data RemoveError
  = RemoveUnauthorized AuthorizationError
  | RemoveLifecycle LifecycleError
  | RemoveNotRegistered
  deriving (Eq, Show)

-- Organizer removes a participant while registration is open (plain remove).
removeParticipant
  :: (TournamentRepository m, RegistrationRepository m, Transactional m)
  => UserId
  -> TournamentId
  -> Participant
  -> m (Either RemoveError ())
removeParticipant caller tid participant =
  withTxEither $ do
    tournament <- Repo.getTournament tid
    case preChecks tournament of
      Left e -> pure (Left e)
      Right () -> do
        regs <- Repo.listRegistrations tid
        case filter ((== participant) . registrationParticipant) regs of
          []      -> pure (Left RemoveNotRegistered)
          (r : _) -> do
            Repo.deleteRegistration (registrationId r)
            pure (Right ())
  where
    preChecks t = do
      first RemoveUnauthorized (requireTournamentOwner caller t)
      first RemoveLifecycle (requireTournamentState RegistrationOpen t)

listMyRegistrations
  :: (TournamentRepository m, RegistrationRepository m)
  => UserId
  -> m [Tournament]
listMyRegistrations uid = do
  ids <- Repo.listRegisteredTournamentIds uid
  mapM Repo.getTournament ids