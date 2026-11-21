{-# LANGUAGE OverloadedStrings #-}

-- Application.UseCases.SeriesScoring
-- Game-by-game scoring. The organizer picks best of 1, 3 or 5 before any game is recorded.
-- While a match is in progress, a captain (or the player, in 1v1) reports a game score and the
-- other captain confirms it; the organizer or a referee can record or override a game directly.
-- When one side has a confirmed majority of games, the match result is recorded through the
-- existing result logic, acting as the tournament owner.
module Application.UseCases.SeriesScoring
  ( SeriesError(..)
  , GameView(..)
  , SeriesView(..)
  , setSeriesLength
  , reportGame
  , confirmGame
  , readSeries
  ) where

import Data.Char (toLower)
import Data.List (find)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T

import Domain.Ids (UserId, TournamentId)
import Domain.Match (Match(..), MatchId, MatchOutcome(..))
import qualified Domain.Match as DM
import Domain.Participant (Participant(..), Player(..), PlayerName(..), Team(..))
import Domain.Series (MatchGame(..))
import Domain.Tournament (Tournament(..), TournamentState(..))
import Domain.User (User(username), Username(..))
import Application.UseCases.RecordMatchResult (recordMatchResultInTx, RecordMatchResultError)
import Shell.Persistence.Port
  ( MatchRepository, BracketRepository, ParticipantRepository, TournamentRepository
  , UserRepository, MatchRoomRepository, SeriesRepository, Transactional(..) )
import qualified Shell.Persistence.Port as Repo

data SeriesError
  = SeriesForbidden
  | SeriesMatchNotLive
  | SeriesBadGame
  | SeriesBadScore
  | SeriesOutOfOrder
  | SeriesAlreadyConfirmed
  | SeriesNoGame
  | SeriesBadLength
  | SeriesLocked
  | SeriesResultFailed RecordMatchResultError
  deriving (Eq, Show)

data GameView = GameView
  { gvNo         :: Int
  , gvA          :: Int
  , gvB          :: Int
  , gvConfirmed  :: Bool
  , gvBy         :: Text
  , gvCanConfirm :: Bool
  } deriving (Eq, Show)

data SeriesView = SeriesView
  { srsBestOf    :: Int
  , srsGames     :: [GameView]
  , srsCanReport :: Bool
  , srsStaff     :: Bool
  } deriving (Eq, Show)

data Side = SideA | SideB deriving (Eq)

data Ctx = Ctx
  { cMatch :: Match
  , cTourn :: Tournament
  , cStaff :: Bool
  , cSide  :: Maybe Side
  }

same :: Text -> String -> Bool
same u n = map toLower (T.unpack u) == map toLower n

captainIs :: Text -> Participant -> Bool
captainIs uname (Individual (Player (PlayerName n))) = same uname n
captainIs uname (Squad t) = case teamCaptain t of Player (PlayerName n) -> same uname n

loadCtx
  :: (MatchRepository m, TournamentRepository m, UserRepository m, MatchRoomRepository m)
  => UserId -> MatchId -> m Ctx
loadCtx caller mid = do
  m <- Repo.getMatch mid
  t <- Repo.getTournament (matchTournament m)
  refs <- Repo.listReferees (matchTournament m)
  mu <- Repo.findUserById caller
  let uname = maybe "" (unUsername . username) mu
      side | T.null uname = Nothing
           | captainIs uname (matchCompetitorA m) = Just SideA
           | captainIs uname (matchCompetitorB m) = Just SideB
           | otherwise = Nothing
  pure Ctx
    { cMatch = m
    , cTourn = t
    , cStaff = caller == tournamentOwner t || caller `elem` refs
    , cSide  = side
    }

-- Organizer only, and only while no game of this tournament has been recorded.
setSeriesLength
  :: (TournamentRepository m, SeriesRepository m)
  => UserId -> TournamentId -> Int -> m (Either SeriesError ())
setSeriesLength caller tid n = do
  t <- Repo.getTournament tid
  played <- Repo.countSeriesGames tid
  if caller /= tournamentOwner t
    then pure (Left SeriesForbidden)
    else if n `notElem` [1, 3, 5]
      then pure (Left SeriesBadLength)
      else if tournamentState t `elem` [Completed, Cancelled] || played > 0
        then pure (Left SeriesLocked)
        else do
          Repo.setBestOf tid n
          pure (Right ())

-- When a side has a confirmed majority of games, record the match result.
settle
  :: ( MatchRepository m, BracketRepository m, ParticipantRepository m
     , TournamentRepository m, SeriesRepository m, Transactional m )
  => MatchId -> m (Either SeriesError ())
settle mid = do
  m <- Repo.getMatch mid
  t <- Repo.getTournament (matchTournament m)
  bo <- Repo.getBestOf (matchTournament m)
  gs <- Repo.listMatchGames mid
  let done = [ g | g <- gs, gameConfirmed g ]
      winsA = length [ () | g <- done, gameScoreA g > gameScoreB g ]
      winsB = length [ () | g <- done, gameScoreB g > gameScoreA g ]
      need = bo `div` 2 + 1
      winner | winsA >= need = Just (matchCompetitorA m)
             | winsB >= need = Just (matchCompetitorB m)
             | otherwise     = Nothing
  case winner of
    Just w | matchStatus m == DM.InProgress -> do
      r <- recordMatchResultInTx (tournamentOwner t) mid (Winner w)
      pure (either (Left . SeriesResultFailed) (const (Right ())) r)
    _ -> pure (Right ())

reportGame
  :: ( MatchRepository m, BracketRepository m, ParticipantRepository m, TournamentRepository m
     , UserRepository m, MatchRoomRepository m, SeriesRepository m, Transactional m )
  => UserId -> MatchId -> Int -> Int -> Int -> m (Either SeriesError ())
reportGame caller mid gno a b =
  withTxEither $ do
    c <- loadCtx caller mid
    bo <- Repo.getBestOf (matchTournament (cMatch c))
    gs <- Repo.listMatchGames mid
    let confirmedNos = [ gameNo g | g <- gs, gameConfirmed g ]
        involved = cStaff c || isJust (cSide c)
        existing = find ((== gno) . gameNo) gs
    if not involved then pure (Left SeriesForbidden)
    else if matchStatus (cMatch c) /= DM.InProgress then pure (Left SeriesMatchNotLive)
    else if gno < 1 || gno > bo then pure (Left SeriesBadGame)
    else if a < 0 || b < 0 || a == b || a > 999 || b > 999 then pure (Left SeriesBadScore)
    else if not (all (`elem` confirmedNos) [1 .. gno - 1]) then pure (Left SeriesOutOfOrder)
    else case existing of
      Just g | gameConfirmed g && not (cStaff c) -> pure (Left SeriesAlreadyConfirmed)
      _ -> do
        let matchesPending = case existing of
              Just g -> not (gameConfirmed g) && gameScoreA g == a && gameScoreB g == b
                        && gameReportedBy g /= caller
              Nothing -> False
        Repo.upsertMatchGame mid gno a b (cStaff c || matchesPending) caller
        settle mid

confirmGame
  :: ( MatchRepository m, BracketRepository m, ParticipantRepository m, TournamentRepository m
     , UserRepository m, MatchRoomRepository m, SeriesRepository m, Transactional m )
  => UserId -> MatchId -> Int -> m (Either SeriesError ())
confirmGame caller mid gno =
  withTxEither $ do
    c <- loadCtx caller mid
    gs <- Repo.listMatchGames mid
    case find ((== gno) . gameNo) gs of
      Nothing -> pure (Left SeriesNoGame)
      Just g
        | gameConfirmed g -> pure (Left SeriesAlreadyConfirmed)
        | matchStatus (cMatch c) /= DM.InProgress -> pure (Left SeriesMatchNotLive)
        | cStaff c || (isJust (cSide c) && gameReportedBy g /= caller) -> do
            Repo.upsertMatchGame mid gno (gameScoreA g) (gameScoreB g) True (gameReportedBy g)
            settle mid
        | otherwise -> pure (Left SeriesForbidden)

readSeries
  :: (MatchRepository m, TournamentRepository m, UserRepository m, MatchRoomRepository m, SeriesRepository m)
  => UserId -> MatchId -> m (Either SeriesError SeriesView)
readSeries caller mid = do
  c <- loadCtx caller mid
  bo <- Repo.getBestOf (matchTournament (cMatch c))
  gs <- Repo.listMatchGames mid
  views <- mapM (\g -> do
                   mu <- Repo.findUserById (gameReportedBy g)
                   pure GameView
                     { gvNo = gameNo g
                     , gvA = gameScoreA g
                     , gvB = gameScoreB g
                     , gvConfirmed = gameConfirmed g
                     , gvBy = maybe "unknown" (unUsername . username) mu
                     , gvCanConfirm = not (gameConfirmed g)
                         && (cStaff c || (isJust (cSide c) && gameReportedBy g /= caller))
                     }) gs
  let live = matchStatus (cMatch c) == DM.InProgress
      involved = cStaff c || isJust (cSide c)
  pure (Right SeriesView
    { srsBestOf = bo
    , srsGames = views
    , srsCanReport = live && involved
    , srsStaff = cStaff c
    })