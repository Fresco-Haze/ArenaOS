module Domain.Ids
  ( TournamentId(..)
  , BracketId(..)
  , BracketNodeId(..)
  , UserId(..)
  -- add other cross-referenced ID types here as they come up
  ) where

newtype TournamentId = TournamentId { unTournamentId :: Int } deriving (Show, Eq)
newtype BracketId = BracketId { unBracketId :: Int } deriving (Show, Eq)
newtype BracketNodeId = BracketNodeId { unBracketNodeId :: Int } deriving (Show, Eq, Ord)
newtype UserId = UserId { unUserId :: Int } deriving (Show, Eq, Ord)