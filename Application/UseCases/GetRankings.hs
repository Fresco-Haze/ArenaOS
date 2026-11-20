module Application.UseCases.GetRankings
  ( getRankings
  , counted
  , tournamentFacts
  , PublicFact(..)
  , loadPublicFacts
  , loadMatchScores
  , rankingsFrom
  , lobbyChampionOf
  , playedFrom
  , tournamentPlayed
  ) where

import Data.Maybe (mapMaybe)
import qualified Data.Map.Strict as Map

import qualified Domain.Match as M
import qualified Domain.Tournament as T
import Domain.Participant (Participant)
import Domain.Registration (registrationParticipant)

import Engine.Champion (matchOutcomeWinner, tournamentChampionWith)
import Engine.Standings (MatchScores)
import Domain.Scoreable (unEFootballScore)
import Engine.Rankings (RankingEntry, computeRankings, computePlayed)

import Shell.Persistence.Port (TournamentRepository, BracketRepository, MatchRepository, RegistrationRepository, EFootballScoreRepository, LobbyRepository, ParticipantRepository)
import qualified Engine.Lobby as EL
import qualified Shell.Persistence.Port as Repo

-- Public tournaments past Draft, not cancelled, optionally of one game.
-- Computed on read, never stored, so corrections and reopenings are always reflected.
getRankings
  :: (TournamentRepository m, BracketRepository m, MatchRepository m, EFootballScoreRepository m, RegistrationRepository m, LobbyRepository m, ParticipantRepository m)
  => Maybe T.Game
  -> Int
  -> m [RankingEntry]
getRankings mGame limitN = do
  ts <- Repo.listAllTournaments
  facts <- mapM tournamentFacts (filter (counted mGame) ts)
  pure (take limitN (computeRankings (concat facts)))

counted :: Maybe T.Game -> T.Tournament -> Bool
counted mGame t =
  T.tournamentVisibility t == T.Public
    && T.tournamentState t /= T.Draft
    && T.tournamentState t /= T.Cancelled
    && maybe True (\g -> T.tournamentGame t == Just g) mGame

tournamentFacts
  :: (BracketRepository m, MatchRepository m, EFootballScoreRepository m, RegistrationRepository m, LobbyRepository m, ParticipantRepository m)
  => T.Tournament -> m [(Maybe Participant, [Participant])]
tournamentFacts t | T.tournamentKind t == T.LobbyKind = lobbyFact t
tournamentFacts t = case T.tournamentBracket t of
  Nothing  -> pure []
  Just bid -> do
    (bracket, nodes) <- Repo.getBracket bid
    matches <- Repo.listMatchesForBracket bid
    scores <- if T.tournamentFormat t == T.RoundRobin && T.tournamentState t == T.Completed
                then loadMatchScores matches
                else pure []
    let winners = mapMaybe completedWinner matches
        champ
          | T.tournamentState t == T.Completed =
              tournamentChampionWith scores (T.tournamentFormat t) bracket nodes matches
          | otherwise = Nothing
    pure [(champ, winners)]

-- A lobby has no bracket and no matches, so its only fact is its champion:
-- one title, and no match wins. A tie at the top, or an unfinished lobby, has none.
lobbyFact
  :: (RegistrationRepository m, LobbyRepository m, ParticipantRepository m)
  => T.Tournament -> m [(Maybe Participant, [Participant])]
lobbyFact t = do
  champ <- lobbyChampionOf t
  pure [(champ, [])]

lobbyChampionOf
  :: (RegistrationRepository m, LobbyRepository m, ParticipantRepository m)
  => T.Tournament -> m (Maybe Participant)
lobbyChampionOf t
  | T.tournamentKind t /= T.LobbyKind || T.tournamentState t /= T.Completed = pure Nothing
  | otherwise = do
      let tid = T.tournamentId t
      settings <- Repo.getLobbySettings tid
      regs <- Repo.listRegistrations tid
      let people = map registrationParticipant regs
      ids <- mapM Repo.resolveParticipant people
      rounds <- Repo.listLobbyRounds tid
      let table = EL.lobbyStandings settings ids (map snd rounds)
          byId = zip ids people
      pure (EL.lobbyChampion table >>= \pid -> lookup pid byId)

completedWinner :: M.Match -> Maybe Participant
completedWinner m
  | M.matchStatus m == M.Completed = matchOutcomeWinner m
  | otherwise                      = Nothing

-- Goals per match, read the same way the round robin table reads them.
loadMatchScores :: EFootballScoreRepository m => [M.Match] -> m MatchScores
loadMatchScores ms = do
  rows <- mapM (\m -> fmap ((,) (M.matchId m)) <$> Repo.getEFootballScore (M.matchId m)) ms
  pure [ (mid, (unEFootballScore a, unEFootballScore b)) | Just (mid, (a, b)) <- rows ]
-- Everything the rankings and the players pages need, per public tournament.
-- Loading it is the expensive part, so the API keeps one copy for a minute.
data PublicFact = PublicFact
  { pubTournament :: T.Tournament
  , pubEntrants   :: [Participant]
  , pubChampion   :: Maybe Participant
  , pubWinners    :: [Participant]
  , pubPlayed     :: [Participant]
  }

loadPublicFacts
  :: (TournamentRepository m, BracketRepository m, MatchRepository m, RegistrationRepository m, EFootballScoreRepository m, LobbyRepository m, ParticipantRepository m)
  => m [PublicFact]
loadPublicFacts = do
  ts <- Repo.listAllTournaments
  mapM one (filter (counted Nothing) ts)
  where
    one t = do
      regs <- Repo.listRegistrations (T.tournamentId t)
      fs <- tournamentFacts t
      let (champ, winners) = case fs of
            ((c, w) : _) -> (c, w)
            []           -> (Nothing, [])
      played <- tournamentPlayed t
      pure (PublicFact t (map registrationParticipant regs) champ winners played)

rankingsFrom :: Maybe T.Game -> Int -> [PublicFact] -> [RankingEntry]
rankingsFrom mGame limitN facts =
  take limitN (computeRankings [ (pubChampion f, pubWinners f) | f <- facts, inGame (pubTournament f) ])
  where
    inGame t = maybe True (\g -> T.tournamentGame t == Just g) mGame


-- v0.15: everyone who took part in a completed match of this tournament, once
-- per match. A match with no result (NoContest) does not count as played.
-- Lobbies have no matches, so they add nothing here.
tournamentPlayed
  :: (BracketRepository m, MatchRepository m)
  => T.Tournament -> m [Participant]
tournamentPlayed t
  | T.tournamentKind t == T.LobbyKind = pure []
  | otherwise = case T.tournamentBracket t of
      Nothing  -> pure []
      Just bid -> do
        matches <- Repo.listMatchesForBracket bid
        pure (concatMap participantsOf matches)
  where
    participantsOf m = case (M.matchStatus m, M.matchOutcome m) of
      (M.Completed, Just (M.Winner _))           -> both m
      (M.Completed, Just M.Draw)                 -> both m
      (M.Completed, Just (M.Forfeit _))          -> both m
      (M.Completed, Just (M.Disqualification _)) -> both m
      _                                          -> []
    both m = [M.matchCompetitorA m, M.matchCompetitorB m]

-- v0.15: matches played per player (lowercased name), from the same facts the
-- rankings use and with the same game filter.
playedFrom :: Maybe T.Game -> [PublicFact] -> Map.Map String Int
playedFrom mGame facts =
  computePlayed (concat [ pubPlayed f | f <- facts, inGame (pubTournament f) ])
  where
    inGame t = maybe True (\g -> T.tournamentGame t == Just g) mGame