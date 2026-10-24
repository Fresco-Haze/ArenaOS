module Application.UseCases.GetRankings
  ( getRankings
  ) where

import Data.Maybe (mapMaybe)

import qualified Domain.Match as M
import qualified Domain.Tournament as T
import Domain.Participant (Participant)

import Engine.Champion (matchOutcomeWinner, tournamentChampion)
import Engine.Rankings (RankingEntry, computeRankings)

import Shell.Persistence.Port (TournamentRepository, BracketRepository, MatchRepository)
import qualified Shell.Persistence.Port as Repo

-- Public tournaments past Draft, not cancelled. Computed on read, never stored,
-- so corrections and reopenings are always reflected.
getRankings
  :: (TournamentRepository m, BracketRepository m, MatchRepository m)
  => Int
  -> m [RankingEntry]
getRankings limitN = do
  ts <- Repo.listAllTournaments
  facts <- mapM tournamentFacts (filter counted ts)
  pure (take limitN (computeRankings (concat facts)))

counted :: T.Tournament -> Bool
counted t =
  T.tournamentVisibility t == T.Public
    && T.tournamentState t /= T.Draft
    && T.tournamentState t /= T.Cancelled

tournamentFacts
  :: (BracketRepository m, MatchRepository m)
  => T.Tournament -> m [(Maybe Participant, [Participant])]
tournamentFacts t = case T.tournamentBracket t of
  Nothing  -> pure []
  Just bid -> do
    (bracket, nodes) <- Repo.getBracket bid
    matches <- Repo.listMatchesForBracket bid
    let winners = mapMaybe completedWinner matches
        champ
          | T.tournamentState t == T.Completed =
              tournamentChampion (T.tournamentFormat t) bracket nodes matches
          | otherwise = Nothing
    pure [(champ, winners)]

completedWinner :: M.Match -> Maybe Participant
completedWinner m
  | M.matchStatus m == M.Completed = matchOutcomeWinner m
  | otherwise                      = Nothing