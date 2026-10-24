module Application.UseCases.JoinRequests
  ( joinOrRequest
  , joinOrRequestAt
  , JoinOutcome(..)
  , JoinOrRequestError(..)
  , cancelJoinRequest
  , CancelRequestError(..)
  , approveJoinRequest
  , ApproveError(..)
  , declineJoinRequest
  , DeclineError(..)
  , listJoinRequestsForOwner
  , ListRequestsError(..)
  , JoinRequestEntry(..)
  ) where

import Control.Monad (unless, forM_)
import Data.Bifunctor (bimap, first)
import qualified Data.Text as T
import Data.Time (UTCTime)

import Domain.Ids (UserId)
import Domain.JoinRequest (JoinRequestStatus(..))
import Domain.Notification (NotificationKind(..))
import Domain.Participant (Participant(..), Player(..), PlayerName(..))
import Domain.Registration (registrationParticipant)
import Domain.Tournament
  ( Tournament, TournamentId, TournamentState(RegistrationOpen)
  , tournamentMaxParticipants, tournamentParticipantMode, tournamentRequireApproval, tournamentOwner, tournamentRegistrationDeadline
  , ParticipantMode(..) )
import Domain.User (Username(..), User(username))

import Application.Internal.Authorization (AuthorizationError, requireTournamentOwner, requireVisibleToViewer)
import Application.Internal.LifecycleTransition (LifecycleError, requireTournamentState)
import Application.UseCases.RegisterParticipant (JoinTournamentError(..), joinTournament)

import Shell.Persistence.Port
  ( TournamentRepository
  , ParticipantRepository
  , RegistrationRepository
  , RegistrationId
  , UserRepository
  , JoinRequestRepository
  , NotificationRepository
  , NewRegistration(..)
  , Transactional(..)
  )
import qualified Shell.Persistence.Port as Repo

data JoinOutcome
  = Joined RegistrationId
  | RequestPending
  deriving (Eq, Show)

data JoinOrRequestError
  = JoinFailed JoinTournamentError
  | JoinRequestAlreadyPending
  | JoinRequestDeclined
  | JoinDeadlinePassed
  deriving (Eq, Show)

-- Approval off: exactly joinTournament. Approval on: record a Pending request.
joinOrRequest
  :: ( TournamentRepository m, ParticipantRepository m, RegistrationRepository m
     , UserRepository m, JoinRequestRepository m, NotificationRepository m, Transactional m )
  => UserId
  -> TournamentId
  -> m (Either JoinOrRequestError JoinOutcome)
joinOrRequest caller tid = do
  tournament <- Repo.getTournament tid
  if tournamentRequireApproval tournament
    then withTxEither (requestPath caller tid tournament)
    else bimap JoinFailed Joined <$> joinTournament caller tid

-- Same as joinOrRequest, but refuses once the registration deadline has passed.
-- The caller passes the current time, so the check stays pure and testable.
joinOrRequestAt
  :: ( TournamentRepository m, ParticipantRepository m, RegistrationRepository m
     , UserRepository m, JoinRequestRepository m, NotificationRepository m, Transactional m )
  => UTCTime
  -> UserId
  -> TournamentId
  -> m (Either JoinOrRequestError JoinOutcome)
joinOrRequestAt now caller tid = do
  tournament <- Repo.getTournament tid
  let visible = either (const False) (const True) (requireVisibleToViewer (Just caller) tournament)
  case tournamentRegistrationDeadline tournament of
    Just d | visible && now > d -> pure (Left JoinDeadlinePassed)
    _ -> joinOrRequest caller tid

requestPath
  :: (UserRepository m, RegistrationRepository m, JoinRequestRepository m, NotificationRepository m)
  => UserId
  -> TournamentId
  -> Tournament
  -> m (Either JoinOrRequestError JoinOutcome)
requestPath caller tid tournament =
  case preChecks of
    Left e -> pure (Left (JoinFailed e))
    Right () -> do
      mUser <- Repo.findUserById caller
      case mUser of
        Nothing -> pure (Left (JoinFailed JoinAccountMissing))
        Just u -> do
          existing <- Repo.findUserRegistration tid caller
          regs <- Repo.listRegistrations tid
          mReq <- Repo.getJoinRequest tid caller
          let participant = Individual (Player (PlayerName (T.unpack (unUsername (username u)))))
          case (existing, mReq) of
            (Just _, _) -> pure (Left (JoinFailed JoinAlreadyJoined))
            (Nothing, Just JoinPending)  -> pure (Left JoinRequestAlreadyPending)
            (Nothing, Just JoinDeclined) -> pure (Left JoinRequestDeclined)
            (Nothing, _)
              | participant `elem` map registrationParticipant regs ->
                  pure (Left (JoinFailed JoinNameTaken))
              | length regs >= tournamentMaxParticipants tournament ->
                  pure (Left (JoinFailed JoinFull))
              | otherwise -> do
                  Repo.saveJoinRequest tid caller JoinPending
                  Repo.addNotification (tournamentOwner tournament) NoteJoinRequested tid
                    (Just (T.unpack (unUsername (username u))))
                  pure (Right RequestPending)
  where
    preChecks = do
      first JoinNotVisible (requireVisibleToViewer (Just caller) tournament)
      first JoinLifecycle (requireTournamentState RegistrationOpen tournament)
      unless (tournamentParticipantMode tournament == IndividualOnly) (Left JoinSquadOnly)

data CancelRequestError = NoPendingRequest
  deriving (Eq, Show)

-- A player cancels their own pending request.
cancelJoinRequest
  :: (JoinRequestRepository m, Transactional m)
  => UserId
  -> TournamentId
  -> m (Either CancelRequestError ())
cancelJoinRequest caller tid =
  withTxEither $ do
    mReq <- Repo.getJoinRequest tid caller
    case mReq of
      Just JoinPending -> do
        Repo.deleteJoinRequest tid caller
        pure (Right ())
      _ -> pure (Left NoPendingRequest)

-- ===== Organizer: approve, decline, list =====

data JoinRequestEntry = JoinRequestEntry UserId T.Text JoinRequestStatus
  deriving (Eq, Show)

data ApproveError
  = ApproveUnauthorized AuthorizationError
  | ApproveLifecycle LifecycleError
  | ApproveNoRequest
  | ApproveAlreadyJoined
  | ApproveNameTaken
  | ApproveFull
  | ApproveAccountMissing
  deriving (Eq, Show)

-- Approves a Pending (or previously Declined) request: creates the registration.
approveJoinRequest
  :: ( TournamentRepository m, ParticipantRepository m, RegistrationRepository m
     , UserRepository m, JoinRequestRepository m, NotificationRepository m, Transactional m )
  => UserId
  -> TournamentId
  -> UserId
  -> m (Either ApproveError RegistrationId)
approveJoinRequest caller tid target =
  withTxEither $ do
    tournament <- Repo.getTournament tid
    case approvePreChecks tournament of
      Left err -> pure (Left err)
      Right () -> do
        mReq <- Repo.getJoinRequest tid target
        mUser <- Repo.findUserById target
        case (mReq, mUser) of
          (Nothing, _) -> pure (Left ApproveNoRequest)
          (_, Nothing) -> pure (Left ApproveAccountMissing)
          (Just _, Just u) -> do
            existing <- Repo.findUserRegistration tid target
            regs <- Repo.listRegistrations tid
            let player = Player (PlayerName (T.unpack (unUsername (username u))))
                participant = Individual player
            case existing of
              Just _ -> pure (Left ApproveAlreadyJoined)
              Nothing
                | participant `elem` map registrationParticipant regs ->
                    pure (Left ApproveNameTaken)
                | length regs >= tournamentMaxParticipants tournament ->
                    pure (Left ApproveFull)
                | otherwise -> do
                    Repo.savePlayer player
                    pid <- Repo.resolveParticipant participant
                    rid <- Repo.createUserRegistration target NewRegistration
                      { newRegistrationTournament  = tid
                      , newRegistrationParticipant = pid
                      }
                    Repo.saveJoinRequest tid target JoinApproved
                    Repo.addNotification target NoteRequestApproved tid Nothing
                    pure (Right rid)
  where
    approvePreChecks t = do
      first ApproveUnauthorized (requireTournamentOwner caller t)
      first ApproveLifecycle (requireTournamentState RegistrationOpen t)

data DeclineError
  = DeclineUnauthorized AuthorizationError
  | DeclineLifecycle LifecycleError
  | DeclineNoRequest
  deriving (Eq, Show)

-- Declines a request; if the player is already registered, removes them too.
declineJoinRequest
  :: (TournamentRepository m, RegistrationRepository m, JoinRequestRepository m, NotificationRepository m, Transactional m)
  => UserId
  -> TournamentId
  -> UserId
  -> m (Either DeclineError ())
declineJoinRequest caller tid target =
  withTxEither $ do
    tournament <- Repo.getTournament tid
    case declinePreChecks tournament of
      Left err -> pure (Left err)
      Right () -> do
        mReq <- Repo.getJoinRequest tid target
        case mReq of
          Nothing -> pure (Left DeclineNoRequest)
          Just _ -> do
            existing <- Repo.findUserRegistration tid target
            forM_ existing Repo.deleteRegistration
            Repo.saveJoinRequest tid target JoinDeclined
            Repo.addNotification target NoteRequestDeclined tid Nothing
            pure (Right ())
  where
    declinePreChecks t = do
      first DeclineUnauthorized (requireTournamentOwner caller t)
      first DeclineLifecycle (requireTournamentState RegistrationOpen t)

data ListRequestsError = ListUnauthorized AuthorizationError
  deriving (Eq, Show)

listJoinRequestsForOwner
  :: (TournamentRepository m, UserRepository m, JoinRequestRepository m)
  => UserId
  -> TournamentId
  -> m (Either ListRequestsError [JoinRequestEntry])
listJoinRequestsForOwner caller tid = do
  tournament <- Repo.getTournament tid
  case requireTournamentOwner caller tournament of
    Left e -> pure (Left (ListUnauthorized e))
    Right () -> do
      rows <- Repo.listJoinRequests tid
      entries <- mapM toEntry rows
      pure (Right [ e | Just e <- entries ])
  where
    toEntry (u, st) = do
      mUser <- Repo.findUserById u
      pure (fmap (\usr -> JoinRequestEntry u (unUsername (username usr)) st) mUser)