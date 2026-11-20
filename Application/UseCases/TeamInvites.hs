{-# LANGUAGE OverloadedStrings #-}

module Application.UseCases.TeamInvites
  ( inviteToTeam
  , revokeTeamInvite
  , listPendingForTeam
  , listMyTeamInvites
  , acceptTeamInvite
  , declineTeamInvite
  , listJoinedTeams
  , TeamInviteError(..)
  , PendingInvite(..)
  , MyInvite(..)
  ) where

import Control.Monad (unless)
import Data.Char (toLower)
import Data.Text (Text)
import qualified Data.Text as T

import Domain.Ids (UserId)
import Domain.Participant (Player(..), PlayerName(..), Team(..), TeamName(..))
import Domain.TeamInvite (TeamInviteStatus(..))
import Domain.User (User(username, userId), Username(..))
import Shell.Persistence.Port (ParticipantRepository, UserRepository, TeamInviteRepository)
import qualified Shell.Persistence.Port as Repo

data TeamInviteError
  = InviteNotOwner
  | InviteUserNotFound
  | InviteAlreadyMember
  | InviteAlreadyPending
  | InviteNotFound
  | InviteRosterLocked
  deriving (Eq, Show)

-- invitee id and username
data PendingInvite = PendingInvite UserId Text
  deriving (Eq, Show)

-- team and the username of whoever invited you
data MyInvite = MyInvite TeamName Text
  deriving (Eq, Show)

isOwner :: ParticipantRepository m => UserId -> TeamName -> m Bool
isOwner caller tn = do
  owner <- Repo.getTeamOwner tn
  pure (owner == Just caller)

isMember :: Text -> Team -> Bool
isMember uname team = any same (teamCaptain team : teamMembers team)
  where
    same (Player (PlayerName n)) = map toLower n == map toLower (T.unpack uname)

-- The team's owner invites a registered player by username.
inviteToTeam
  :: (ParticipantRepository m, UserRepository m, TeamInviteRepository m)
  => UserId -> TeamName -> Text -> m (Either TeamInviteError ())
inviteToTeam caller tn rawName = do
  ok <- isOwner caller tn
  if not ok
    then pure (Left InviteNotOwner)
    else do
      mUser <- Repo.findUserByUsername (Username (T.strip rawName))
      case mUser of
        Nothing -> pure (Left InviteUserNotFound)
        Just u -> do
          team <- Repo.getTeam tn
          existing <- Repo.getTeamInvite tn (userId u)
          if isMember (unUsername (username u)) team
            then pure (Left InviteAlreadyMember)
            else if existing == Just InvitePending
              then pure (Left InviteAlreadyPending)
              else do
                Repo.createTeamInvite tn (userId u) caller
                pure (Right ())

revokeTeamInvite
  :: (ParticipantRepository m, TeamInviteRepository m)
  => UserId -> TeamName -> UserId -> m (Either TeamInviteError ())
revokeTeamInvite caller tn target = do
  ok <- isOwner caller tn
  if not ok
    then pure (Left InviteNotOwner)
    else do
      Repo.deleteTeamInvite tn target
      pure (Right ())

listPendingForTeam
  :: (ParticipantRepository m, UserRepository m, TeamInviteRepository m)
  => UserId -> TeamName -> m (Either TeamInviteError [PendingInvite])
listPendingForTeam caller tn = do
  ok <- isOwner caller tn
  if not ok
    then pure (Left InviteNotOwner)
    else do
      ids <- Repo.listPendingTeamInvites tn
      entries <- mapM (\uid -> fmap (\u -> PendingInvite uid (unUsername (username u))) <$> Repo.findUserById uid) ids
      pure (Right [ e | Just e <- entries ])

listMyTeamInvites
  :: (UserRepository m, TeamInviteRepository m)
  => UserId -> m [MyInvite]
listMyTeamInvites uid = do
  rows <- Repo.listInvitesForUser uid
  mapM (\(tn, by) -> do
          mu <- Repo.findUserById by
          pure (MyInvite tn (maybe "someone" (unUsername . username) mu))) rows

-- Accepting adds the player's username to the team roster.
acceptTeamInvite
  :: (ParticipantRepository m, UserRepository m, TeamInviteRepository m)
  => UserId -> TeamName -> m (Either TeamInviteError ())
acceptTeamInvite uid tn = do
  st <- Repo.getTeamInvite tn uid
  mUser <- Repo.findUserById uid
  case (st, mUser) of
    (Just InvitePending, Just u) -> do
      team <- Repo.getTeam tn
      let uname = unUsername (username u)
          player = Player (PlayerName (T.unpack uname))
      Repo.savePlayer player
      unless (isMember uname team) $
        Repo.saveTeam (team { teamMembers = teamMembers team ++ [player] })
      Repo.setTeamInviteStatus tn uid InviteAccepted
      pure (Right ())
    _ -> pure (Left InviteNotFound)

declineTeamInvite
  :: TeamInviteRepository m
  => UserId -> TeamName -> m (Either TeamInviteError ())
declineTeamInvite uid tn = do
  st <- Repo.getTeamInvite tn uid
  case st of
    Just InvitePending -> do
      Repo.setTeamInviteStatus tn uid InviteDeclined
      pure (Right ())
    _ -> pure (Left InviteNotFound)

-- Teams the player is on but did not create.
listJoinedTeams
  :: (ParticipantRepository m, UserRepository m, TeamInviteRepository m)
  => UserId -> m [Team]
listJoinedTeams uid = do
  mUser <- Repo.findUserById uid
  case mUser of
    Nothing -> pure []
    Just u -> do
      names <- Repo.listTeamNamesByMember (PlayerName (T.unpack (unUsername (username u))))
      owned <- mapM (\tn -> (== Just uid) <$> Repo.getTeamOwner tn) names
      mapM Repo.getTeam [ tn | (tn, False) <- zip names owned ]