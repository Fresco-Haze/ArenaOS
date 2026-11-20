module Application.UseCases.MyMatchHistory
  ( MatchHistoryEntry(..)
  , MatchResult(..)
  , myMatchHistory
  ) where

import Data.Char (toLower)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime)

import Domain.Ids (UserId, TournamentId)
import Domain.Match (Match(..), MatchId, MatchOutcome(..))
import Domain.Participant (Participant(..), Player(..), PlayerName(..), Team(..), TeamName(..))
import Domain.Tournament (Tournament(..), TournamentName(..))
import Domain.User (User(username), Username(..))
import Shell.Persistence.Port (MatchRepository, TournamentRepository, UserRepository, MatchHistoryRepository)
import qualified Shell.Persistence.Port as Repo

data MatchResult = ResultWin | ResultLoss | ResultDraw
  deriving (Eq, Show)

data MatchHistoryEntry = MatchHistoryEntry
  { mheMatchId        :: MatchId
  , mheTournamentId   :: TournamentId
  , mheTournamentName :: String
  , mheOpponent       :: String
  , mheResult         :: MatchResult
  , mheWhen           :: Maybe UTCTime
  } deriving (Eq, Show)

participantLabel :: Participant -> String
participantLabel (Individual (Player (PlayerName n))) = n
participantLabel (Squad t) = unTeamName (teamName t)

hasUser :: Text -> Participant -> Bool
hasUser uname (Individual (Player (PlayerName n))) = same uname n
hasUser uname (Squad t) =
  any (\(Player (PlayerName n)) -> same uname n) (teamCaptain t : teamMembers t)

same :: Text -> String -> Bool
same u n = map toLower (T.unpack u) == map toLower n

myMatchHistory
  :: (MatchRepository m, TournamentRepository m, UserRepository m, MatchHistoryRepository m)
  => UserId -> Int -> m [MatchHistoryEntry]
myMatchHistory uid limitN = do
  mUser <- Repo.findUserById uid
  case mUser of
    Nothing -> pure []
    Just u -> do
      let uname = unUsername (username u)
      ids <- Repo.listMatchIdsForPlayer (PlayerName (T.unpack uname)) limitN
      entries <- mapM (entryFor uname) ids
      pure [ e | Just e <- entries ]

entryFor
  :: (MatchRepository m, TournamentRepository m)
  => Text -> MatchId -> m (Maybe MatchHistoryEntry)
entryFor uname mid = do
  m <- Repo.getMatch mid
  t <- Repo.getTournament (matchTournament m)
  let a = matchCompetitorA m
      b = matchCompetitorB m
      (mine, other) = if hasUser uname a then (a, b) else (b, a)
      verdict p = if p == mine then ResultWin else ResultLoss
      result = case matchOutcome m of
        Nothing                    -> Nothing
        Just (Winner p)            -> Just (verdict p)
        Just (Forfeit p)           -> Just (verdict p)
        Just (Disqualification p)  -> Just (verdict p)
        Just Draw                  -> Just ResultDraw
        Just NoContest             -> Just ResultDraw
  pure (fmap (\r -> MatchHistoryEntry
           { mheMatchId        = matchId m
           , mheTournamentId   = matchTournament m
           , mheTournamentName = unTournamentName (tournamentName t)
           , mheOpponent       = participantLabel other
           , mheResult         = r
           , mheWhen           = matchScheduledStart m
           }) result)