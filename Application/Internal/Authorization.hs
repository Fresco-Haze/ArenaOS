module Application.Internal.Authorization
  ( AuthorizationError(..)
  , requireTournamentOwner
  , requireAdministrator
  ) where

import Domain.Tournament (Tournament(..))
import Domain.Ids (UserId)
import Domain.Role (Role(..))

-- Reusable Application-layer permission checks. Two independent
-- mechanisms live here, sharing one error type because they're the
-- same conceptual category (authorization failures), not because
-- they're the same check -- mirrors LifecycleError's two
-- constructors for two different lifecycle rules under one type.
--
-- requireTournamentOwner: resource-ownership authorization ("does
-- this caller own this specific tournament"). Shared across every
-- use case that needs to verify the caller owns the tournament
-- they're acting on. Takes an already-loaded Tournament rather than
-- doing its own repository lookup -- the calling use case already
-- has to load the tournament regardless, so this stays pure and
-- testable without a Monad/repository constraint.
--
-- requireAdministrator: system-role authorization ("is this caller
-- authorized regardless of resource ownership"). Takes an
-- already-loaded [Role] -- the calling use case fetches it via
-- RoleRepository.getRoles first, same "caller already has the data"
-- shape. Deliberately a separate mechanism from ownership -- these
-- must never collapse into one check.
data AuthorizationError
  = NotTournamentOwner
  | NotAdministrator
  deriving (Eq, Show)

requireTournamentOwner :: UserId -> Tournament -> Either AuthorizationError ()
requireTournamentOwner uid tournament
  | uid == tournamentOwner tournament = Right ()
  | otherwise                         = Left NotTournamentOwner

requireAdministrator :: [Role] -> Either AuthorizationError ()
requireAdministrator roles
  | Administrator `elem` roles = Right ()
  | otherwise                  = Left NotAdministrator