module Domain.TournamentError
  ( TournamentError(..)
  ) where

data TournamentError
  = TournamentNotComplete
  | TournamentAlreadyCompleted
  | TournamentAlreadyCancelled
  | TournamentPaused
  deriving (Eq, Show)