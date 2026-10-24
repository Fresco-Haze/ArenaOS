module Application.UseCases.JoinRequests
  ( joinOrRequest
  , JoinOutcome(..)
  , JoinOrRequestError(..)
  , cancelJoinRequest
  , CancelRequestError(..)
  ) where

import Control.Monad (unless)
import Data.Bifunctor (bimap, first)
import qualified Data.Text as T

import Domain.Ids (UserId)
import Domain.JoinRequest (JoinRequestStatus(..))
import Domain.Participant (Participant(..), Player(..), PlayerName(..))
import Domain.Registration (registrationParticipant)
import Domain.Tournament
  ( Tournament, TournamentId, TournamentState(RegistrationOpen)
  , tournamentMaxParticipants, tournamentParticipantMode, tournamentRequireApproval
  , ParticipantMode(..) )
import Domain.User (Username(..), User(username))

import Application.Internal.Authorization (requireVisibleToViewer)
import Application.Internal.LifecycleTransition (requireTournamentState)
import Application.UseCases.RegisterParticipant (JoinTournamentError(..), joinTournament)

import Shell.Persistence.Port
  ( TournamentRepository
  , ParticipantRepository
  , RegistrationRepository
  , RegistrationId
  , UserRepository
  , JoinRequestRepository
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
  deriving (Eq, Show)

-- Approval off: exactly joinTournament. Approval on: record a Pending request.
joinOrRequest
  :: ( TournamentRepository m, ParticipantRepository m, RegistrationRepository m
     , UserRepository m, JoinRequestRepository m, Transactional m )
  => UserId
  -> TournamentId
  -> m (Either JoinOrRequestError JoinOutcome)
joinOrRequest caller tid = do
  tournament <- Repo.getTournament tid
  if tournamentRequireApproval tournament
    then withTxEither (requestPath caller tid tournament)
    else bimap JoinFailed Joined <$> joinTournament caller tid

requestPath
  :: (UserRepository m, RegistrationRepository m, JoinRequestRepository m)
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