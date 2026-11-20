{-# LANGUAGE OverloadedStrings #-}

-- Application.UseCases.Substitutions
-- Roster lock and substitutions. A team's roster is locked while it is registered in a
-- tournament that is RegistrationClosed, InProgress or Paused. While locked, new invites and
-- invite acceptances are refused, and the team owner asks staff (the tournament organizer or
-- a referee) to approve a swap instead.
module Application.UseCases.Substitutions
  ( SubstitutionError(..)
  , SubView(..)
  , isLockedState
  , lockingTournament
  , inviteToTeamUnlocked
  , acceptTeamInviteUnlocked
  , requestSubstitution
  , decideSubstitution
  , listTournamentSubstitutions
  , teamSubstitutionState
  ) where

import Data.Char (toLower)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import Domain.Ids (UserId, TournamentId(..))
import Domain.Participant (Player(..), PlayerName(..), Team(..), TeamName(..))
import Domain.Substitution (Substitution(..), SubstitutionStatus(..))
import Domain.Tournament (Tournament(..), TournamentName(..), TournamentState(..))
import Domain.User (User(username, userId), Username(..))
import Application.UseCases.TeamInvites (TeamInviteError(..))
import qualified Application.UseCases.TeamInvites as TInv
import Shell.Persistence.Port
  ( ParticipantRepository, TournamentRepository, UserRepository
  , TeamInviteRepository, MatchRoomRepository, SubstitutionRepository )
import qualified Shell.Persistence.Port as Repo

data SubstitutionError
  = SubNotOwner
  | SubNotStaff
  | SubNotRegistered
  | SubRosterNotLocked
  | SubBadOutPlayer
  | SubInUserNotFound
  | SubInAlreadyOnTeam
  | SubAlreadyPending
  | SubNotFound
  | SubNotPending
  deriving (Eq, Show)

-- id, team, tournament id, member going out, username coming in, requested by, status
data SubView = SubView
  { svId       :: Int
  , svTeam     :: String
  , svTournament :: Int
  , svOut      :: String
  , svIncoming :: Text
  , svBy       :: Text
  , svStatus   :: SubstitutionStatus
  } deriving (Eq, Show)

isLockedState :: TournamentState -> Bool
isLockedState s = s `elem` [RegistrationClosed, InProgress, Paused]

pn :: Player -> String
pn (Player (PlayerName n)) = n

sameName :: String -> String -> Bool
sameName a b = map toLower a == map toLower b

-- The first tournament that currently locks this team'"'"'s roster, with its name.
lockingTournament
  :: (TournamentRepository m, SubstitutionRepository m)
  => TeamName -> m (Maybe (TournamentId, String))
lockingTournament tn = do
  ids <- Repo.listTournamentIdsForTeam tn
  ts <- mapM (\i -> do { t <- Repo.getTournament i; pure (i, t) }) ids
  pure (listToMaybe [ (i, unTournamentName (tournamentName t)) | (i, t) <- ts, isLockedState (tournamentState t) ])

inviteToTeamUnlocked
  :: ( ParticipantRepository m, UserRepository m, TeamInviteRepository m
     , TournamentRepository m, SubstitutionRepository m )
  => UserId -> TeamName -> Text -> m (Either TeamInviteError ())
inviteToTeamUnlocked caller tn who = do
  l <- lockingTournament tn
  case l of
    Just _  -> pure (Left InviteRosterLocked)
    Nothing -> TInv.inviteToTeam caller tn who

acceptTeamInviteUnlocked
  :: ( ParticipantRepository m, UserRepository m, TeamInviteRepository m
     , TournamentRepository m, SubstitutionRepository m )
  => UserId -> TeamName -> m (Either TeamInviteError ())
acceptTeamInviteUnlocked uid tn = do
  l <- lockingTournament tn
  case l of
    Just _  -> pure (Left InviteRosterLocked)
    Nothing -> TInv.acceptTeamInvite uid tn

requestSubstitution
  :: (ParticipantRepository m, UserRepository m, TournamentRepository m, SubstitutionRepository m)
  => UserId -> TeamName -> TournamentId -> String -> Text -> m (Either SubstitutionError Int)
requestSubstitution caller tn tid outName inName = do
  owner <- Repo.getTeamOwner tn
  ids <- Repo.listTournamentIdsForTeam tn
  if owner /= Just caller
    then pure (Left SubNotOwner)
    else if unTournamentId tid `notElem` map unTournamentId ids
      then pure (Left SubNotRegistered)
      else do
        t <- Repo.getTournament tid
        if not (isLockedState (tournamentState t))
          then pure (Left SubRosterNotLocked)
          else do
            team <- Repo.getTeam tn
            let everyone = map pn (teamMembers team)
                bench = [ m | m <- everyone, not (sameName m (pn (teamCaptain team))) ]
            case filter (sameName outName) bench of
              [] -> pure (Left SubBadOutPlayer)
              (outCanon : _) -> do
                mUser <- Repo.findUserByUsername (Username (T.strip inName))
                case mUser of
                  Nothing -> pure (Left SubInUserNotFound)
                  Just u ->
                    if any (sameName (T.unpack (unUsername (username u)))) everyone
                      then pure (Left SubInAlreadyOnTeam)
                      else do
                        existing <- Repo.listSubstitutionsForTeam tn
                        let pending = [ () | s <- existing, subStatus s == SubPending
                                           , unTournamentId (subTournament s) == unTournamentId tid ]
                        if not (null pending)
                          then pure (Left SubAlreadyPending)
                          else Right <$> Repo.createSubstitution tn tid outCanon (userId u) caller

decideSubstitution
  :: ( ParticipantRepository m, UserRepository m, TournamentRepository m
     , MatchRoomRepository m, SubstitutionRepository m )
  => UserId -> TournamentId -> Int -> Bool -> m (Either SubstitutionError ())
decideSubstitution caller tid sid approve = do
  ms <- Repo.getSubstitution sid
  case ms of
    Nothing -> pure (Left SubNotFound)
    Just s ->
      if unTournamentId (subTournament s) /= unTournamentId tid
        then pure (Left SubNotFound)
        else do
          t <- Repo.getTournament tid
          refs <- Repo.listReferees tid
          if not (caller == tournamentOwner t || caller `elem` refs)
            then pure (Left SubNotStaff)
            else if subStatus s /= SubPending
              then pure (Left SubNotPending)
              else if not approve
                then do
                  Repo.setSubstitutionStatus sid caller SubDeclined
                  pure (Right ())
                else do
                  team <- Repo.getTeam (subTeam s)
                  mu <- Repo.findUserById (subInUser s)
                  case mu of
                    Nothing -> pure (Left SubInUserNotFound)
                    Just u -> do
                      let inN = T.unpack (unUsername (username u))
                          roster = teamMembers team
                          present = any (sameName (subOutPlayer s) . pn) roster
                          alreadyIn = any (sameName inN . pn) roster
                      if not present
                        then pure (Left SubBadOutPlayer)
                        else if alreadyIn
                          then pure (Left SubInAlreadyOnTeam)
                          else do
                            let newPlayer = Player (PlayerName inN)
                                kept = [ p | p <- roster, not (sameName (subOutPlayer s) (pn p)) ]
                            Repo.savePlayer newPlayer
                            Repo.saveTeam team { teamMembers = kept ++ [newPlayer] }
                            Repo.setSubstitutionStatus sid caller SubApproved
                            pure (Right ())

toView :: UserRepository m => Substitution -> m SubView
toView s = do
  inU <- Repo.findUserById (subInUser s)
  byU <- Repo.findUserById (subRequestedBy s)
  let nameOf = maybe "unknown" (unUsername . username)
  pure SubView
    { svId         = subId s
    , svTeam       = unTeamName (subTeam s)
    , svTournament = unTournamentId (subTournament s)
    , svOut        = subOutPlayer s
    , svIncoming   = nameOf inU
    , svBy         = nameOf byU
    , svStatus     = subStatus s
    }

listTournamentSubstitutions
  :: (TournamentRepository m, UserRepository m, MatchRoomRepository m, SubstitutionRepository m)
  => UserId -> TournamentId -> m (Either SubstitutionError [SubView])
listTournamentSubstitutions caller tid = do
  t <- Repo.getTournament tid
  refs <- Repo.listReferees tid
  if not (caller == tournamentOwner t || caller `elem` refs)
    then pure (Left SubNotStaff)
    else do
      rows <- Repo.listSubstitutionsForTournament tid
      Right <$> mapM toView rows

-- For the team owner: the tournament that locks the roster (id and name), and all requests.
teamSubstitutionState
  :: ( ParticipantRepository m, UserRepository m, TournamentRepository m, SubstitutionRepository m )
  => UserId -> TeamName -> m (Either SubstitutionError (Maybe (Int, String), [SubView]))
teamSubstitutionState caller tn = do
  owner <- Repo.getTeamOwner tn
  if owner /= Just caller
    then pure (Left SubNotOwner)
    else do
      l <- lockingTournament tn
      rows <- Repo.listSubstitutionsForTeam tn
      views <- mapM toView rows
      pure (Right (fmap (\(i, n) -> (unTournamentId i, n)) l, views))