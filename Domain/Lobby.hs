-- Domain.Lobby
-- Pure data for lobby (battle royale style) tournaments. No logic here; the
-- scoring rules are in Engine.Lobby.
module Domain.Lobby
  ( LobbySettings(..)
  , defaultLobbySettings
  , GameEntry(..)
  ) where

-- Points per kill, and points for 1st, 2nd, ... place. Places past the end of
-- the list score 0. The defaults match the lobby_settings table.
data LobbySettings = LobbySettings
  { lobbyKillPoints      :: Int
  , lobbyPlacementPoints :: [Int]
  } deriving (Eq, Show)

defaultLobbySettings :: LobbySettings
defaultLobbySettings = LobbySettings 1 [10, 6, 5, 4, 3, 2, 1, 1]

-- One participant's result in one game.
data GameEntry a = GameEntry
  { entryParticipant :: a
  , entryPlacement   :: Int
  , entryKills       :: Int
  } deriving (Eq, Show)