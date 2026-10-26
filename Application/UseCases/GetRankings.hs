module Application.UseCases.GetRankings
  ( getRankings
  , counted
  , tournamentFacts
  , PublicFact(..)
  , loadPublicFacts
  , rankingsFrom
  ) where

import Data.Maybe (mapMaybe)

import qualified Domain.Match as M
import qualified Domain.Tournament as T
import Domain.Participant (Participant)
import Domain.Registration (registrationParticipant)

import Engine.Champion (matchOutcomeWinner, tournamentChampion)
import Engine.Rankings (RankingEntry, computeRankings)

import Shell.Persistence.Port (TournamentRepository, BracketRepository, MatchRepository, RegistrationRepository)
import qualified Shell.Persistence.Port as Repo

-- Public tournaments past Draft, not cancelled, optionally of one game.
-- Computed on read, never stored, so corrections and reopenings are always reflected.
getRankings
  :: (TournamentRepository m, BracketRepository m, MatchRepository m)
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

-- Everything the rankings and the players pages need, per public tournament.
-- Loading it is the expensive part, so the API keeps one copy for a minute.
data PublicFact = PublicFact
  { pubTournament :: T.Tournament
  , pubEntrants   :: [Participant]
  , pubChampion   :: Maybe Participant
  , pubWinners    :: [Participant]
  }

loadPublicFacts
  :: (TournamentRepository m, BracketRepository m, MatchRepository m, RegistrationRepository m)
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
      pure (PublicFact t (map registrationParticipant regs) champ winners)

rankingsFrom :: Maybe T.Game -> Int -> [PublicFact] -> [RankingEntry]
rankingsFrom mGame limitN facts =
  take limitN (computeRankings [ (pubChampion f, pubWinners f) | f <- facts, inGame (pubTournament f) ])
  where
    inGame t = maybe True (\g -> T.tournamentGame t == Just g) mGame
