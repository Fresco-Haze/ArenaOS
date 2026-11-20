module Application.UseCases.Announcements
  ( postAnnouncement
  , listTournamentAnnouncements
  , removeAnnouncement
  , cleanAnnouncementBody
  , AnnouncementError(..)
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Domain.Announcement (Announcement)
import Domain.Ids (UserId)
import Domain.Tournament (TournamentId)

import Shell.Persistence.Port (TournamentRepository, AnnouncementRepository)
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization
  (AuthorizationError, requireTournamentOwner, requireVisibleToViewer)

data AnnouncementError
  = AnnouncementUnauthorized AuthorizationError
  | AnnouncementBodyEmpty
  | AnnouncementBodyTooLong
  | AnnouncementNotFound
  deriving (Eq, Show)

maxAnnouncementLength :: Int
maxAnnouncementLength = 2000

-- Pure: trimmed, 1 to 2000 characters.
cleanAnnouncementBody :: Text -> Either AnnouncementError Text
cleanAnnouncementBody raw
  | T.null s                           = Left AnnouncementBodyEmpty
  | T.length s > maxAnnouncementLength = Left AnnouncementBodyTooLong
  | otherwise                          = Right s
  where s = T.strip raw

-- Owner only.
postAnnouncement
  :: (TournamentRepository m, AnnouncementRepository m)
  => UserId -> TournamentId -> Text -> m (Either AnnouncementError Int)
postAnnouncement uid tid raw = do
  tournament <- Repo.getTournament tid
  case requireTournamentOwner uid tournament of
    Left err -> pure (Left (AnnouncementUnauthorized err))
    Right () -> case cleanAnnouncementBody raw of
      Left err   -> pure (Left err)
      Right body -> Right <$> Repo.addAnnouncement tid uid body

-- Anyone who can see the tournament, signed in or not. Newest first.
listTournamentAnnouncements
  :: (TournamentRepository m, AnnouncementRepository m)
  => Maybe UserId -> TournamentId -> m (Either AnnouncementError [Announcement])
listTournamentAnnouncements viewer tid = do
  tournament <- Repo.getTournament tid
  case requireVisibleToViewer viewer tournament of
    Left err -> pure (Left (AnnouncementUnauthorized err))
    Right () -> Right <$> Repo.listAnnouncements tid

-- Owner only. An announcement id that does not belong to this tournament is NotFound.
removeAnnouncement
  :: (TournamentRepository m, AnnouncementRepository m)
  => UserId -> TournamentId -> Int -> m (Either AnnouncementError ())
removeAnnouncement uid tid aid = do
  tournament <- Repo.getTournament tid
  case requireTournamentOwner uid tournament of
    Left err -> pure (Left (AnnouncementUnauthorized err))
    Right () -> do
      removed <- Repo.deleteAnnouncement tid aid
      pure (if removed then Right () else Left AnnouncementNotFound)