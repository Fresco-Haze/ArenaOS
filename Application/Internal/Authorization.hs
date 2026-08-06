module Application.Internal.Authorization
  ( AuthorizationError(..)
  , requireTournamentOwner
  ) where

import Domain.Tournament (Tournament(..))
import Domain.Ids (UserId)

-- Reusable Application-layer permission check, shared across every
-- use case that needs to verify the caller owns the tournament they're
-- acting on (GenerateBracket, StartMatch, RecordMatchResult,
-- CompleteTournament). Takes an already-loaded Tournament rather than
-- doing its own repository lookup -- the calling use case already has
-- to load the tournament regardless, so this stays pure and testable
-- without a Monad/repository constraint.
data AuthorizationError
  = NotTournamentOwner
  deriving (Eq, Show)

requireTournamentOwner :: UserId -> Tournament -> Either AuthorizationError ()
requireTournamentOwner uid tournament
  | uid == tournamentOwner tournament = Right ()
  | otherwise                         = Left NotTournamentOwner