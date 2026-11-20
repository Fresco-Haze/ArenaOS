-- Application.UseCases.CheckInDeadline
-- Check-in with an optional closing time. The organizer opens check-in and may set a
-- deadline; a player checking themselves in after it is refused. The organizer can still
-- check participants in by hand, which this module does not touch.
module Application.UseCases.CheckInDeadline
  ( startCheckInUntil
  , checkInSelfAt
  , isoTime
  ) where

import Data.Time (UTCTime, defaultTimeLocale, formatTime)

import Domain.Ids (UserId, TournamentId)
import Application.UseCases.CheckIn (CheckInError(..), startCheckIn, checkInSelf)
import Shell.Persistence.Port
  ( TournamentRepository, RegistrationRepository, CheckInRepository
  , CheckInDeadlineRepository, Transactional )
import qualified Shell.Persistence.Port as Repo

isoTime :: UTCTime -> String
isoTime = formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

-- Opens check-in; Nothing clears any earlier deadline.
startCheckInUntil
  :: ( TournamentRepository m, RegistrationRepository m, Transactional m
     , CheckInRepository m, CheckInDeadlineRepository m )
  => Maybe UTCTime -> UserId -> TournamentId -> m (Either CheckInError ())
startCheckInUntil mUntil caller tid = do
  r <- startCheckIn caller tid
  case r of
    Left e   -> pure (Left e)
    Right () -> do
      Repo.setCheckInDeadline tid (fmap isoTime mUntil)
      pure (Right ())

-- The caller passes the current time as an ISO string, so this stays pure and testable.
checkInSelfAt
  :: ( TournamentRepository m, RegistrationRepository m, Transactional m
     , CheckInRepository m, CheckInDeadlineRepository m )
  => String -> UserId -> TournamentId -> m (Either CheckInError ())
checkInSelfAt nowS uid tid = do
  d <- Repo.getCheckInDeadline tid
  case d of
    Just s | s < nowS -> pure (Left CheckInNotOpen)
    _                 -> checkInSelf uid tid