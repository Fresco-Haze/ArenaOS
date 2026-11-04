-- Engine.Lobby
-- Pure: scoring, standings and champion for lobby (battle royale style)
-- tournaments. No database and no Tournament type. A participant can be any
-- type with Eq, so the rules can be tested on their own.
-- LobbySettings, defaultLobbySettings and GameEntry live in Domain.Lobby and
-- are re-exported here.
module Engine.Lobby
  ( LobbySettings(..)
  , defaultLobbySettings
  , parsePlacementPoints
  , GameEntry(..)
  , LobbyError(..)
  , validateGame
  , entryPoints
  , LobbyStanding(..)
  , lobbyStandings
  , lobbyRanks
  , lobbyChampion
  ) where

import Data.Char (isDigit, isSpace)
import Data.List (dropWhileEnd, sort, sortBy)
import Data.Ord (comparing, Down(..))

import Domain.Lobby (LobbySettings(..), defaultLobbySettings, GameEntry(..))

-- "10, 6,5" -> [10,6,5]. 1 to 100 entries, each a whole number from 0 to 1000.
parsePlacementPoints :: String -> Either String [Int]
parsePlacementPoints raw
  | length parts > 100           = Left "at most 100 places can score"
  | any (not . validToken) parts = Left "placement points must be whole numbers from 0 to 1000, separated by commas"
  | otherwise                    = Right (map read parts)
  where
    parts = map trim (splitCommas raw)
    trim = dropWhileEnd isSpace . dropWhile isSpace
    validToken t = not (null t) && length t <= 4 && all isDigit t && (read t :: Int) <= 1000

splitCommas :: String -> [String]
splitCommas s = case break (== ',') s of
  (a, [])       -> [a]
  (a, _ : rest) -> a : splitCommas rest

data LobbyError
  = NoEntries
  | UnknownParticipant
  | DuplicateParticipant
  | MissingParticipant
  | NegativeKills
  | BadPlacements
  deriving (Eq, Show)

-- A game must cover exactly the registered participants, once each, with
-- placements 1..N (no ties) and no negative kills.
validateGame :: Eq a => [a] -> [GameEntry a] -> Either LobbyError ()
validateGame registered entries
  | null entries                                                   = Left NoEntries
  | any ((< 0) . entryKills) entries                               = Left NegativeKills
  | hasDuplicates players                                          = Left DuplicateParticipant
  | any (`notElem` registered) players                             = Left UnknownParticipant
  | any (`notElem` players) registered                             = Left MissingParticipant
  | sort (map entryPlacement entries) /= [1 .. length entries]     = Left BadPlacements
  | otherwise                                                      = Right ()
  where
    players = map entryParticipant entries

hasDuplicates :: Eq a => [a] -> Bool
hasDuplicates []       = False
hasDuplicates (x : xs) = x `elem` xs || hasDuplicates xs

entryPoints :: LobbySettings -> GameEntry a -> Int
entryPoints s e = placementScore + entryKills e * lobbyKillPoints s
  where
    placementScore
      | entryPlacement e < 1 = 0
      | otherwise = case drop (entryPlacement e - 1) (lobbyPlacementPoints s) of
          (p : _) -> p
          []      -> 0

data LobbyStanding a = LobbyStanding
  { lsEntrant       :: a
  , lsPoints        :: Int
  , lsKills         :: Int
  , lsBestPlacement :: Maybe Int
  , lsGamesPlayed   :: Int
  } deriving (Eq, Show)

-- Everyone registered gets a row, even with no games. Ordered by points, then
-- kills, then best single-game placement. Entries for anyone not registered
-- are ignored. Ties keep registration order, so they are not a resolved rank.
lobbyStandings :: Eq a => LobbySettings -> [a] -> [[GameEntry a]] -> [LobbyStanding a]
lobbyStandings settings registered games = sortBy order (map standingFor registered)
  where
    standingFor p =
      let mine = [ e | g <- games, e <- g, entryParticipant e == p ]
      in LobbyStanding
           { lsEntrant       = p
           , lsPoints        = sum (map (entryPoints settings) mine)
           , lsKills         = sum (map entryKills mine)
           , lsBestPlacement = bestOf (map entryPlacement mine)
           , lsGamesPlayed   = length mine
           }
    bestOf [] = Nothing
    bestOf ps = Just (minimum ps)
    order = comparing (\s -> (Down (lsPoints s), Down (lsKills s), maybe maxBound id (lsBestPlacement s)))

tieKey :: LobbyStanding a -> (Int, Int, Int)
tieKey s = (lsPoints s, lsKills s, maybe maxBound id (lsBestPlacement s))

-- Competition ranking: equal records share a rank (1, 1, 3). The input must
-- already be in table order.
lobbyRanks :: [LobbyStanding a] -> [(Int, LobbyStanding a)]
lobbyRanks ss = [ (1 + length (takeWhile ((/= tieKey s) . tieKey) ss), s) | s <- ss ]

-- The champion is the one player alone at rank 1 who has played a game. A tie
-- at the top after every tiebreaker means no champion.
lobbyChampion :: [LobbyStanding a] -> Maybe a
lobbyChampion ss = case [ s | (1, s) <- lobbyRanks ss ] of
  [s] | lsGamesPlayed s > 0 -> Just (lsEntrant s)
  _                         -> Nothing