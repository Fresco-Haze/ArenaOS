module Application.UseCases.GetPlayers
  ( getPlayers
  , getPlayerProfile
  , PlayerProfile(..)
  ) where

import Data.Char (toLower)
import Data.List (isInfixOf, sortOn)
import Data.Maybe (mapMaybe)

import Domain.Ids (TournamentId(..))
import Domain.Participant (Participant(..), Player(..), PlayerName(..))
import Domain.Registration (registrationParticipant)
import qualified Domain.Tournament as T

import Application.UseCases.GetRankings (counted, tournamentFacts)
import Engine.Players (PlayerFact(..), PlayerSummary(..), summarize)

import Shell.Persistence.Port
  ( TournamentRepository, BracketRepository, MatchRepository, RegistrationRepository )
import qualified Shell.Persistence.Port as Repo

data PlayerProfile = PlayerProfile
  { ppSummary :: PlayerSummary
  , ppHistory :: [(T.Tournament, Bool)]   -- tournament, and whether the player won it
  }

playerNameOf :: Participant -> Maybe String
playerNameOf (Individual (Player (PlayerName n))) = Just n
playerNameOf _                                    = Nothing

-- Public tournaments past Draft, not cancelled (the same set the rankings use).
gather
  :: (TournamentRepository m, BracketRepository m, MatchRepository m, RegistrationRepository m)
  => m [(T.Tournament, PlayerFact)]
gather = do
  ts <- Repo.listAllTournaments
  mapM one (filter (counted Nothing) ts)
  where
    one t = do
      regs <- Repo.listRegistrations (T.tournamentId t)
      fs <- tournamentFacts t
      let (champ, winners) = case fs of
            ((c, w) : _) -> (c, w)
            []           -> (Nothing, [])
          entrants = mapMaybe (playerNameOf . registrationParticipant) regs
      pure (t, PlayerFact entrants (champ >>= playerNameOf) (mapMaybe playerNameOf winners))

-- Directory: optional case-insensitive name search, best players first.
getPlayers
  :: (TournamentRepository m, BracketRepository m, MatchRepository m, RegistrationRepository m)
  => Maybe String -> Int -> m [PlayerSummary]
getPlayers mq limitN = do
  g <- gather
  let matches s = maybe True (\q -> map toLower q `isInfixOf` map toLower (psName s)) mq
  pure (take limitN (filter matches (summarize (map snd g))))

-- Exact (case-sensitive) name. Nothing when the player is in no public tournament.
getPlayerProfile
  :: (TournamentRepository m, BracketRepository m, MatchRepository m, RegistrationRepository m)
  => String -> m (Maybe PlayerProfile)
getPlayerProfile name = do
  g <- gather
  case filter ((== name) . psName) (summarize (map snd g)) of
    []      -> pure Nothing
    (s : _) -> pure (Just (PlayerProfile s history))
      where
        history = sortOn (\(t, _) -> negate (unTournamentId (T.tournamentId t)))
                    [ (t, pfChampion f == Just name) | (t, f) <- g, name `elem` pfEntrants f ]