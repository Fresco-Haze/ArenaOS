-- Application.UseCases.CheckIn
-- Check-in: the organizer opens a window, registered players confirm they are present.
-- Works for bracket and lobby tournaments. Only while registration is open or closed.
-- loadCheckIn follows the tournament page's visibility rule (owner, or public and past Draft).
module Application.UseCases.CheckIn
  ( startCheckIn
  , stopCheckIn
  , checkInSelf
  , setParticipantCheckedIn
  , loadCheckIn
  , CheckInError(..)
  , CheckInView(..)
  ) where

import Data.Bifunctor (first)
import Data.Char (toLower)

import Domain.Ids (UserId)
import Domain.Participant (Participant(..), Player(..), PlayerName(..))
import Domain.Registration (Registration(..))
import Domain.Tournament (Tournament, TournamentId, TournamentState(..))

import Shell.Persistence.Port
  ( TournamentRepository, RegistrationRepository, CheckInRepository, Transactional(..) )
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization
  (AuthorizationError, requireTournamentOwner, requireVisibleToViewer)
import Application.Internal.LifecycleTransition (LifecycleError, requireTournamentStateNotIn)

data CheckInError
  = CheckInUnauthorized AuthorizationError
  | CheckInLifecycle LifecycleError
  | CheckInNotOpen
  | CheckInNotRegistered
  deriving (Eq, Show)

data CheckInView = CheckInView
  { checkInOpen           :: Bool
  , checkedInParticipants :: [Participant]
  , viewerCheckedIn       :: Bool
  } deriving (Eq, Show)

requireCheckInPhase :: Tournament -> Either LifecycleError ()
requireCheckInPhase =
  requireTournamentStateNotIn [Draft, Published, InProgress, Paused, Completed, Cancelled]

ownerInPhase :: UserId -> Tournament -> Either CheckInError ()
ownerInPhase caller t = do
  first CheckInUnauthorized (requireTournamentOwner caller t)
  first CheckInLifecycle (requireCheckInPhase t)

-- Individual players are the same when their names differ only by case.
sameCheckInParticipant :: Participant -> Participant -> Bool
sameCheckInParticipant (Individual (Player (PlayerName a))) (Individual (Player (PlayerName b))) =
  map toLower a == map toLower b
sameCheckInParticipant a b = a == b

startCheckIn
  :: (TournamentRepository m, RegistrationRepository m, Transactional m, CheckInRepository m)
  => UserId -> TournamentId -> m (Either CheckInError ())
startCheckIn caller tid =
  withTxEither $ do
    tournament <- Repo.getTournament tid
    case ownerInPhase caller tournament of
      Left e   -> pure (Left e)
      Right () -> Right <$> Repo.openCheckIn tid

stopCheckIn
  :: (TournamentRepository m, RegistrationRepository m, Transactional m, CheckInRepository m)
  => UserId -> TournamentId -> m (Either CheckInError ())
stopCheckIn caller tid =
  withTxEither $ do
    tournament <- Repo.getTournament tid
    case ownerInPhase caller tournament of
      Left e   -> pure (Left e)
      Right () -> Right <$> Repo.closeCheckIn tid

-- A player checks themselves in (only registrations made through their account).
checkInSelf
  :: (TournamentRepository m, RegistrationRepository m, Transactional m, CheckInRepository m)
  => UserId -> TournamentId -> m (Either CheckInError ())
checkInSelf caller tid =
  withTxEither $ do
    tournament <- Repo.getTournament tid
    case first CheckInLifecycle (requireCheckInPhase tournament) of
      Left e -> pure (Left e)
      Right () -> do
        open <- Repo.isCheckInOpen tid
        if not open
          then pure (Left CheckInNotOpen)
          else do
            mReg <- Repo.findUserRegistration tid caller
            case mReg of
              Nothing  -> pure (Left CheckInNotRegistered)
              Just rid -> Right <$> Repo.setCheckedIn rid True

-- The organizer checks a participant in or out. Does not need check-in to be open.
setParticipantCheckedIn
  :: (TournamentRepository m, RegistrationRepository m, Transactional m, CheckInRepository m)
  => UserId -> TournamentId -> Participant -> Bool -> m (Either CheckInError ())
setParticipantCheckedIn caller tid participant flag =
  withTxEither $ do
    tournament <- Repo.getTournament tid
    case ownerInPhase caller tournament of
      Left e -> pure (Left e)
      Right () -> do
        regs <- Repo.listRegistrations tid
        case filter (sameCheckInParticipant participant . registrationParticipant) regs of
          []      -> pure (Left CheckInNotRegistered)
          (r : _) -> Right <$> Repo.setCheckedIn (registrationId r) flag

loadCheckIn
  :: (TournamentRepository m, RegistrationRepository m, CheckInRepository m)
  => Maybe UserId -> TournamentId -> m (Either CheckInError CheckInView)
loadCheckIn viewer tid = do
  tournament <- Repo.getTournament tid
  case first CheckInUnauthorized (requireVisibleToViewer viewer tournament) of
    Left e -> pure (Left e)
    Right () -> do
      open <- Repo.isCheckInOpen tid
      checked <- Repo.listCheckedIn tid
      regs <- Repo.listRegistrations tid
      mine <- case viewer of
        Nothing  -> pure Nothing
        Just uid -> Repo.findUserRegistration tid uid
      pure (Right CheckInView
        { checkInOpen           = open
        , checkedInParticipants = [ registrationParticipant r | r <- regs, registrationId r `elem` checked ]
        , viewerCheckedIn       = maybe False (`elem` checked) mine
        })