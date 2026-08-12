# ArenaOS

**Author:** Jeremiah

A game-agnostic tournament management platform, built in pure Haskell.

ArenaOS handles the backend logic for running tournament brackets — creating a tournament, registering participants, generating the bracket, and automatically advancing winners through each round as match results come in — with full accounts, ownership, lifecycle management, and an audit trail of everything that happens to a tournament.

**Status: v0.5**

Five milestones in, driven entirely through a CLI:

## v0.1 — Core Engine

- Create a tournament, register participants, generate a single-elimination bracket
- Play through matches (start → record result), with automatic advancement of winners through each round, including bye handling for uneven participant counts
- Complete the tournament once a champion is determined

## v0.2 — Accounts, Authentication & Ownership

- User registration, login/logout, password management
- Every tournament has an owner; every mutating action is authorized against that ownership (`requireTournamentOwner`)
- File-based CLI sessions (`login` persists a session; commands can act as the logged-in user)
- Organizers can list their own tournaments

## v0.3 — Lifecycle, Editing, Dashboard & History

- A real tournament lifecycle: `Draft → Published → RegistrationOpen → RegistrationClosed → InProgress → Completed`, with cancellation permitted from any non-terminal state. Every transition is its own authorized, validated use case — no more implicit or skippable states.
- Tournament editing (name, visibility, format, max participants) with lifecycle-aware guards — editable up through registration closing, locked once a tournament starts
- A session-driven Organizer Dashboard — tournament counts by lifecycle state, at a glance, for the logged-in user
- A full tournament history — every meaningful lifecycle transition, configuration change, and cancellation (with reason) is recorded as an append-only, ownership-protected audit trail

## v0.4 — Teams, Call of Duty & PUBG Registration

- **Team-based registration**, alongside individual players. A `Participant` is either an `Individual` player or a `Squad` (team) — the existing registration pipeline already supported this polymorphically; v0.4 added the missing `createTeam` use case (captain must be a team member, team names must be unique) to actually exercise it.
- A retrofit to `registerParticipant` itself: registration now correctly enforces tournament state (`RegistrationOpen` only) and capacity limits, closing a gap between the original requirement and its implementation.
- **Two concrete team-based games**, built as independent, deliberately non-abstracted consumers of team registration: **Call of Duty** and **PUBG**. Each rejects individual registrants and delegates team registrants through the standard pipeline, inheriting its state and capacity rules for free.
- No persisted "game" concept, roster-size modeling, or scoring logic was introduced for either game — real competitive rules for both were researched directly, and neither justified more than a team-only registration gate at this stage. That's a deliberate choice: v0.4 is concrete, hardcoded, and intentionally *not* a general game-configuration framework. A future milestone (v0.5) will use what these two real implementations reveal to design that abstraction properly, rather than guessing at it upfront.

v0.4 remains CLI-only, same as prior milestones. A frontend is planned but deferred to a future HTTP/web phase — the goal has been to get the domain model and business rules right first, not build a UI on top of a shifting foundation.

## v0.5 — Registration Abstraction & Architecture Investigation

- **`registerTeamOnly`**, a single reusable application-layer combinator (reject an individual, delegate a team through the standard registration pipeline, wrap its error) extracted after CoD and PUBG's registration use cases were compared and found alpha-equivalent — two independent implementations converging on the identical shape, not a resemblance assumed from two similar-looking files. `registerCodParticipant` and `registerPubgParticipant` now delegate to it as thin, pure translation adapters, preserving their own outward error vocabulary while the actual invariant lives once.
- **No other v0.4/v0.5 duplication was collapsed** on sight. CoD's `CodRequiresTeam` and PUBG's `PubgRequiresTeam` looked identical from the start; only once both implementations and both test suites were checked for actual behavioral or semantic divergence — and found to have none — was the shared combinator extracted.
- **An architecture investigation into Match/bracket support**, comparing what ArenaOS's current `Match`, `MatchOutcome`, and bracket-generation engine actually assume against what real competitive PUBG requires. This surfaced two independent findings, deliberately not merged into one: ArenaOS's bracket engine is pairwise by construction (from `Match`'s two competitor slots down through bracket topology, seeding, and advancement) versus PUBG's N-team matches; and `MatchOutcome` represents a single categorical result versus PUBG's per-team ranked, points-based result. Neither was implemented. Both a real single-elimination-only implementation gap (`DoubleElimination` and `RoundRobin` are declared `TournamentFormat` values with no corresponding engine behavior — confirmed pre-existing, unrelated to PUBG) and the PUBG-shaped tensions themselves were documented rather than acted on, since none of them are yet justified by repeated demand inside ArenaOS itself — only `registerTeamOnly` had that evidence.

v0.5 intentionally shipped one small, well-earned abstraction rather than a general game-configuration framework speculatively built from a single external domain's rules. The Match/bracket findings remain on record for a future milestone, if and when ArenaOS's own requirements — not PUBG's — call for them.

## Architecture

A layered design, separating pure domain logic from persistence and orchestration:

- **Domain** — core types (Tournament, Match, Bracket, Participant, Team, User, TournamentHistory) with no dependency on storage or IO
- **Engine** — pure bracket logic: validation, bracket generation, seeding, bye resolution, advancement, materialization
- **Application** — use cases that orchestrate the engine and domain rules against persistence (tournament lifecycle transitions, editing, dashboard, history, accounts, matches, team creation, game-specific registration)
- **Shell** — SQLite persistence layer, plus file-based CLI sessions
- **CLI** — a thin command dispatcher over the use cases; all business logic lives below this layer, not in it

Two cross-cutting rules hold throughout: every mutating use case checks ownership before doing anything else (`Application.Internal.Authorization`), and every lifecycle-sensitive use case validates tournament state before mutating (`Application.Internal.LifecycleTransition`). Persistence favors narrow, single-purpose update methods over whole-record saves wherever a use case only ever needs to change one thing.

## Testing

An hspec integration suite covers the full stack — golden-path lifecycles, bye-path bracket generation, error paths (wrong state, non-owner, invalid transitions), the full v0.3 lifecycle/editing/history state machine, team creation, and CoD/PUBG registration (individual rejection, successful team registration, rejection outside the registration window).

Run the suite:

```
cabal test
```

## Usage

Build:

```
cabal build
```

Run a command:

```
cabal run arenaos -- <command> [arguments]
```

Most commands are actor-first, taking `<userId>` as the first argument. Session-driven commands, like `dashboard`, act on whoever is currently logged in instead.

```
register-user <username> <email> <password>
login <username> <password>
logout

create-tournament <userId> <name> <organizer> <maxParticipants>
publish-tournament <userId> <tournamentId>
open-registration <userId> <tournamentId>
close-registration <userId> <tournamentId>
generate-bracket <userId> <tournamentId>
start-tournament <userId> <tournamentId>
cancel-tournament <userId> <tournamentId> <reason>
complete-tournament <userId> <tournamentId>

update-tournament-name <userId> <tournamentId> <name>
update-tournament-visibility <userId> <tournamentId> <visibility>
update-tournament-format <userId> <tournamentId> <format>
update-tournament-max-participants <userId> <tournamentId> <n>

register <tournamentId> <playerName>
create-team <teamName> <captainName> [member1 member2 ...]
register-cod <tournamentId> <teamName> <captainName> [member1 member2 ...]
register-pubg <tournamentId> <teamName> <captainName> [member1 member2 ...]

dashboard
history <userId> <tournamentId>
```