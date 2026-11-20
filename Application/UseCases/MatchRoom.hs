{-# LANGUAGE OverloadedStrings #-}

module Application.UseCases.MatchRoom
  ( MatchRoomError(..)
  , LobbyCodeView(..)
  , EvidenceItem(..)
  , ChatItem(..)
  , postMatchMessage
  , listMatchChat
  , setMatchLobbyCode
  , readMatchLobbyCode
  , uploadEvidence
  , listMatchEvidence
  , readEvidenceImage
  , removeEvidence
  , assignReferee
  , unassignReferee
  , listTournamentReferees
  ) where

import Data.ByteString (ByteString)
import Data.Char (toLower)
import Data.Text (Text)
import qualified Data.Text as T

import Domain.Ids (UserId, TournamentId)
import Domain.Match (Match(..), MatchId)
import Domain.Participant (Participant(..), Player(..), PlayerName(..), Team(..))
import Domain.Tournament (Tournament(..))
import Domain.User (User(..), Username(..))
import Shell.Persistence.Port
  (MatchRepository, TournamentRepository, UserRepository, MatchRoomRepository)
import qualified Shell.Persistence.Port as Repo

data MatchRoomError
  = RoomForbidden
  | RoomNotFound
  | RoomUserNotFound
  | RoomAlreadyReferee
  | RoomBadCode
  | RoomTooManyEvidence
  | RoomBadMessage
  deriving (Eq, Show)

-- The code (if one was shared) and whether the caller may change it.
data LobbyCodeView = LobbyCodeView (Maybe Text) Bool
  deriving (Eq, Show)

-- id, uploader username, note, created at, may the caller delete it
data EvidenceItem = EvidenceItem Int Text (Maybe Text) Text Bool
  deriving (Eq, Show)

data Roles = Roles
  { isOwnerR   :: Bool
  , isRefereeR :: Bool
  , isPlayerR  :: Bool
  }

anyRole :: Roles -> Bool
anyRole r = isOwnerR r || isRefereeR r || isPlayerR r

staff :: Roles -> Bool
staff r = isOwnerR r || isRefereeR r

maxEvidence :: Int
maxEvidence = 12

same :: Text -> String -> Bool
same u n = map toLower (T.unpack u) == map toLower n

hasUser :: Text -> Participant -> Bool
hasUser uname (Individual (Player (PlayerName n))) = same uname n
hasUser uname (Squad t) =
  any (\(Player (PlayerName n)) -> same uname n) (teamCaptain t : teamMembers t)

rolesFor
  :: (MatchRepository m, TournamentRepository m, UserRepository m, MatchRoomRepository m)
  => UserId -> MatchId -> m Roles
rolesFor uid mid = do
  match <- Repo.getMatch mid
  tournament <- Repo.getTournament (matchTournament match)
  refs <- Repo.listReferees (matchTournament match)
  mUser <- Repo.findUserById uid
  let uname = maybe "" (unUsername . username) mUser
  pure Roles
    { isOwnerR   = uid == tournamentOwner tournament
    , isRefereeR = uid `elem` refs
    , isPlayerR  = not (T.null uname)
                   && any (hasUser uname) [matchCompetitorA match, matchCompetitorB match]
    }

-- ===== Lobby code =====

setMatchLobbyCode
  :: (MatchRepository m, TournamentRepository m, UserRepository m, MatchRoomRepository m)
  => UserId -> MatchId -> Text -> m (Either MatchRoomError ())
setMatchLobbyCode uid mid code = do
  r <- rolesFor uid mid
  let c = T.strip code
  if not (staff r)
    then pure (Left RoomForbidden)
    else if T.null c || T.length c > 64
      then pure (Left RoomBadCode)
      else do
        Repo.setLobbyCode mid uid c
        _ <- Repo.addMatchMessage mid (Just uid) "log" "set the lobby code"
        pure (Right ())

readMatchLobbyCode
  :: (MatchRepository m, TournamentRepository m, UserRepository m, MatchRoomRepository m)
  => UserId -> MatchId -> m (Either MatchRoomError LobbyCodeView)
readMatchLobbyCode uid mid = do
  r <- rolesFor uid mid
  if not (anyRole r)
    then pure (Left RoomForbidden)
    else do
      c <- Repo.getLobbyCode mid
      pure (Right (LobbyCodeView c (staff r)))

-- ===== Evidence =====

uploadEvidence
  :: (MatchRepository m, TournamentRepository m, UserRepository m, MatchRoomRepository m)
  => UserId -> MatchId -> Maybe Text -> ByteString -> m (Either MatchRoomError Int)
uploadEvidence uid mid mNote bytes = do
  r <- rolesFor uid mid
  if not (anyRole r)
    then pure (Left RoomForbidden)
    else do
      n <- Repo.countEvidence mid
      if n >= maxEvidence
        then pure (Left RoomTooManyEvidence)
        else do
          eid <- Repo.addEvidence mid uid (mNote >>= clean) bytes
          _ <- Repo.addMatchMessage mid (Just uid) "log" "uploaded a screenshot"
          pure (Right eid)
  where
    clean t = let s = T.take 200 (T.strip t) in if T.null s then Nothing else Just s

listMatchEvidence
  :: (MatchRepository m, TournamentRepository m, UserRepository m, MatchRoomRepository m)
  => UserId -> MatchId -> m (Either MatchRoomError [EvidenceItem])
listMatchEvidence uid mid = do
  r <- rolesFor uid mid
  if not (anyRole r)
    then pure (Left RoomForbidden)
    else do
      rows <- Repo.listEvidence mid
      items <- mapM (\(eid, who, note, at) -> do
                       mu <- Repo.findUserById who
                       pure (EvidenceItem eid (maybe "unknown" (unUsername . username) mu) note at
                               (staff r || who == uid))) rows
      pure (Right items)

readEvidenceImage
  :: (MatchRepository m, TournamentRepository m, UserRepository m, MatchRoomRepository m)
  => UserId -> MatchId -> Int -> m (Either MatchRoomError (Maybe ByteString))
readEvidenceImage uid mid eid = do
  r <- rolesFor uid mid
  if not (anyRole r)
    then pure (Left RoomForbidden)
    else Right <$> Repo.getEvidenceImage mid eid

removeEvidence
  :: (MatchRepository m, TournamentRepository m, UserRepository m, MatchRoomRepository m)
  => UserId -> MatchId -> Int -> m (Either MatchRoomError ())
removeEvidence uid mid eid = do
  r <- rolesFor uid mid
  if not (anyRole r)
    then pure (Left RoomForbidden)
    else do
      uploader <- Repo.getEvidenceUploader mid eid
      case uploader of
        Nothing -> pure (Left RoomNotFound)
        Just who
          | staff r || who == uid -> do
              Repo.deleteEvidence mid eid
              _ <- Repo.addMatchMessage mid (Just uid) "log" "removed a screenshot"
              pure (Right ())
          | otherwise -> pure (Left RoomForbidden)

-- ===== Referees =====

assignReferee
  :: (TournamentRepository m, UserRepository m, MatchRoomRepository m)
  => UserId -> TournamentId -> Text -> m (Either MatchRoomError ())
assignReferee caller tid who = do
  tournament <- Repo.getTournament tid
  if caller /= tournamentOwner tournament
    then pure (Left RoomForbidden)
    else do
      mUser <- Repo.findUserByUsername (Username (T.strip who))
      case mUser of
        Nothing -> pure (Left RoomUserNotFound)
        Just u -> do
          refs <- Repo.listReferees tid
          if userId u `elem` refs
            then pure (Left RoomAlreadyReferee)
            else do
              Repo.addReferee tid (userId u)
              pure (Right ())

unassignReferee
  :: (TournamentRepository m, MatchRoomRepository m)
  => UserId -> TournamentId -> UserId -> m (Either MatchRoomError ())
unassignReferee caller tid target = do
  tournament <- Repo.getTournament tid
  if caller /= tournamentOwner tournament
    then pure (Left RoomForbidden)
    else do
      Repo.removeReferee tid target
      pure (Right ())

listTournamentReferees
  :: (UserRepository m, MatchRoomRepository m)
  => UserId -> TournamentId -> m (Either MatchRoomError [(UserId, Text)])
listTournamentReferees _caller tid = do
  ids <- Repo.listReferees tid
  rows <- mapM (\u -> fmap (\usr -> (u, unUsername (username usr))) <$> Repo.findUserById u) ids
  pure (Right [ x | Just x <- rows ])

-- ===== Chat and admin log =====

-- id, kind ("chat" or "log"), author username (empty for the system), body, created at
data ChatItem = ChatItem Int Text Text Text Text
  deriving (Eq, Show)

postMatchMessage
  :: (MatchRepository m, TournamentRepository m, UserRepository m, MatchRoomRepository m)
  => UserId -> MatchId -> Text -> m (Either MatchRoomError ())
postMatchMessage uid mid raw = do
  r <- rolesFor uid mid
  let b = T.strip raw
  if not (anyRole r)
    then pure (Left RoomForbidden)
    else if T.null b || T.length b > 500
      then pure (Left RoomBadMessage)
      else do
        _ <- Repo.addMatchMessage mid (Just uid) "chat" b
        pure (Right ())

listMatchChat
  :: (MatchRepository m, TournamentRepository m, UserRepository m, MatchRoomRepository m)
  => UserId -> MatchId -> Int -> m (Either MatchRoomError [ChatItem])
listMatchChat uid mid after = do
  r <- rolesFor uid mid
  if not (anyRole r)
    then pure (Left RoomForbidden)
    else do
      rows <- Repo.listMatchMessages mid after
      items <- mapM (\(i, mu, k, b, at) -> do
                       who <- case mu of
                                Nothing -> pure ""
                                Just u  -> maybe "unknown" (unUsername . username) <$> Repo.findUserById u
                       pure (ChatItem i k who b at)) rows
      pure (Right items)
