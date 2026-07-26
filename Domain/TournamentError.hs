module Domain.TournamentError
  ( TournamentError(..)
  ) where

data TournamentError
  = TournamentNotComplete
  | TournamentAlreadyCompleted
  | TournamentAlreadyCancelled
  deriving (Eq, Show)