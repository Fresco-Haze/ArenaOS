module Application.UseCases.GetPlayers
  ( getPlayers
  , getPlayerProfile
  , playersFrom
  , profileFrom
  , PlayerProfile(..)
  ) where

import Data.Char (toLower)
import Data.List (isInfixOf, sortOn)
import Data.Maybe (mapMaybe)

import Domain.Ids (TournamentId(..))
import Domain.Participant (Participant(..), Player(..), PlayerName(..))
import qualified Domain.Tournament as T

import Application.UseCases.GetRankings (PublicFact(..), loadPublicFacts)
import Engine.Players (PlayerFact(..), PlayerSummary(..), summarize)

import Shell.Persistence.Port
  ( TournamentRepository, BracketRepository, MatchRepository, RegistrationRepository, EFootballScoreRepository )

data PlayerProfile = PlayerProfile
  { ppSummary :: PlayerSummary
  , ppHistory :: [(T.Tournament, Bool)]   -- tournament, and whether the player won it
  }

playerNameOf :: Participant -> Maybe String
playerNameOf (Individual (Player (PlayerName n))) = Just n
playerNameOf _                                    = Nothing

toPlayerFact :: PublicFact -> PlayerFact
toPlayerFact f = PlayerFact
  { pfEntrants = mapMaybe playerNameOf (pubEntrants f)
  , pfChampion = pubChampion f >>= playerNameOf
  , pfWinners  = mapMaybe playerNameOf (pubWinners f)
  }

-- Directory: optional case-insensitive name search, best players first.
playersFrom :: Maybe String -> Int -> [PublicFact] -> [PlayerSummary]
playersFrom mq limitN facts =
  take limitN (filter matches (summarize (map toPlayerFact facts)))
  where
    matches s = maybe True (\q -> map toLower q `isInfixOf` map toLower (psName s)) mq

-- Name matched ignoring case ("A" and "a" are one player). Nothing when the
-- player is in no public tournament.
profileFrom :: String -> [PublicFact] -> Maybe PlayerProfile
profileFrom name facts =
  case filter (same name . psName) (summarize (map toPlayerFact facts)) of
    []      -> Nothing
    (s : _) -> Just (PlayerProfile s history)
  where
    same a b = map toLower a == map toLower b
    history = sortOn (\(t, _) -> negate (unTournamentId (T.tournamentId t)))
                [ (pubTournament f, maybe False (same name) (pubChampion f >>= playerNameOf))
                | f <- facts, any (same name) (mapMaybe playerNameOf (pubEntrants f)) ]
getPlayers
  :: (TournamentRepository m, BracketRepository m, MatchRepository m, RegistrationRepository m, EFootballScoreRepository m)
  => Maybe String -> Int -> m [PlayerSummary]
getPlayers mq limitN = playersFrom mq limitN <$> loadPublicFacts

getPlayerProfile
  :: (TournamentRepository m, BracketRepository m, MatchRepository m, RegistrationRepository m, EFootballScoreRepository m)
  => String -> m (Maybe PlayerProfile)
getPlayerProfile name = profileFrom name <$> loadPublicFacts