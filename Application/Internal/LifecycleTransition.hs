-- Application.Internal.LifecycleTransition
-- Pure, reusable cross-cutting helper shared across lifecycle transition
-- use cases (FR-LIFE-007). Mirrors Application.Internal.Authorization:
-- takes an already-loaded Tournament, no repository access of its own.

module Application.Internal.LifecycleTransition
    ( LifecycleError(..)
    , requireTournamentState
    , requireTournamentStateNotIn
    , requireOperationallyActive
    , requireSchedulable
    ) where

import Domain.Tournament (Tournament(..), TournamentState(..))

-- Two constructors, not one: InvalidTransition has a single well-defined
-- "expected" state to report (used by the five equality-check call
-- sites). ForbiddenState (used only by CancelTournament's exclusion
-- check) has no single expected value -- the forbidden set is a list,
-- not a target state -- so it only carries what's actually true: the
-- current state that made the operation invalid.
data LifecycleError
    = InvalidTransition
        { lifecycleCurrentState  :: TournamentState
        , lifecycleExpectedState :: TournamentState
        }
    | ForbiddenState
        { lifecycleCurrentState :: TournamentState
        }
    deriving (Eq, Show)

-- Exact-match check. Used by PublishTournament, OpenRegistration,
-- CloseRegistration, StartTournament, and GenerateBracket's new
-- RegistrationClosed precondition (FR-LIFE-004).
requireTournamentState :: TournamentState -> Tournament -> Either LifecycleError ()
requireTournamentState expected tournament
    | tournamentState tournament == expected = Right ()
    | otherwise = Left (InvalidTransition (tournamentState tournament) expected)

-- Exclusion check. Used only by CancelTournament (FR-LIFE-003):
-- permitted from any state NOT in the forbidden list, rather than
-- requiring one specific state.
requireTournamentStateNotIn :: [TournamentState] -> Tournament -> Either LifecycleError ()
requireTournamentStateNotIn forbidden tournament
    | tournamentState tournament `elem` forbidden = Left (ForbiddenState (tournamentState tournament))
    | otherwise = Right ()
-- | Competitive/progression operations require the tournament to be
-- actively playable -- which, per the existing established workflow,
-- means RegistrationClosed (matches are played before StartTournament
-- is formally called) OR InProgress. Blocks every pre-play state, plus
-- the two new operational-freeze states this guard exists to protect
-- against.
requireOperationallyActive :: Tournament -> Either LifecycleError ()
requireOperationallyActive = requireTournamentStateNotIn
  [Draft, Published, RegistrationOpen, Paused, Completed, Cancelled]

-- | Scheduling operations are permitted whenever the tournament isn't
-- terminally dead -- unlike requireOperationallyActive, Paused is
-- deliberately still allowed here: an organizer needs to be able to
-- reschedule future matches precisely while play is paused (v0.10).
requireSchedulable :: Tournament -> Either LifecycleError ()
requireSchedulable = requireTournamentStateNotIn [Completed, Cancelled]