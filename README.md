# ArenaOS

**Author:** Jeremiah

A game-agnostic tournament management platform, built in pure Haskell, with a React/TypeScript frontend.

ArenaOS handles the backend logic for running tournament brackets — creating a tournament, registering participants, generating the bracket, and automatically advancing winners through each round as match results come in — with full accounts, ownership, lifecycle management, and an audit trail of everything that happens to a tournament. As of v1.0, it's usable as a real web application: organizers manage tournaments through a browser, and spectators can follow a public tournament's bracket live, with no login required.

**Status: v1.0**

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
- No persisted "game" concept, roster-size modeling, or scoring logic was introduced for either game — real competitive rules for both were researched directly, and neither justified more than a team-only registration gate at this stage. That's a deliberate choice: v0.4 is concrete, hardcoded, and intentionally *not* a general game-configuration framework. A future milestone will use what these two real implementations reveal to design that abstraction properly, rather than guessing at it upfront.

## v0.5 — Registration Abstraction & Architecture Investigation

- **`registerTeamOnly`**, a single reusable application-layer combinator (reject an individual, delegate a team through the standard registration pipeline, wrap its error) extracted after CoD and PUBG's registration use cases were compared and found alpha-equivalent — two independent implementations converging on the identical shape, not a resemblance assumed from two similar-looking files. `registerCodParticipant` and `registerPubgParticipant` now delegate to it as thin, pure translation adapters, preserving their own outward error vocabulary while the actual invariant lives once.
- **No other v0.4/v0.5 duplication was collapsed** on sight. CoD's `CodRequiresTeam` and PUBG's `PubgRequiresTeam` looked identical from the start; only once both implementations and both test suites were checked for actual behavioral or semantic divergence — and found to have none — was the shared combinator extracted.
- **An architecture investigation into Match/bracket support**, comparing what ArenaOS's current `Match`, `MatchOutcome`, and bracket-generation engine actually assume against what real competitive PUBG requires. Neither was implemented; both a real single-elimination-only implementation gap (`DoubleElimination` and `RoundRobin` had no corresponding engine behavior at the time) and the PUBG-shaped tensions themselves were documented rather than acted on.

## v0.6 — Administrator Roles, Authorization & Audit Trail

- **A role-based authorization mechanism**, added alongside the existing ownership-based one rather than replacing or generalizing it. `Role` currently has a single constructor, `Administrator` — deliberately not modeled as a mirror of every business responsibility in the system.
- **`grantRole` / `revokeRole`**, non-idempotent by design. An existing Administrator can grant or revoke Administrator status from another user; the system refuses any revocation that would leave the platform with zero Administrators.
- **Administrative retrofits to two existing capabilities**: `set-account-status` now requires an authorized actor and rejects unauthorized attempts before ever checking whether the target exists. A new **Administrator dashboard** provides an unfiltered, platform-wide view of every tournament regardless of owner.
- **An audit trail for security-sensitive administrative actions** — every role grant, role revocation, and account status change is recorded with actor, affected user, operation, and a real UTC timestamp. A failed audit write rolls back the administrative action it would have recorded.

## v0.7 — Match & Competition Semantics: Score-Derived Outcomes, Double Elimination, Round Robin

- **Score-derived match outcomes.** A new `Scoreable` typeclass and a concrete `EFootballScore` type let a game-specific result derive the generic `MatchOutcome` rather than requiring it to be entered directly.
- **Draw and NoContest**, previously silent no-ops, now explicitly rejected for elimination formats since a knockout bracket has no way to progress without a winner. This rule was later made format-aware once Round Robin needed the opposite behavior.
- **Double Elimination**, a full grand-final-with-bracket-reset implementation. A dedicated Losers Bracket topology with round-alternating pure/drop-in structure and cross-seeding, a Grand Final node, and a reset match that only materializes if the Losers Bracket champion actually upsets the Winners Bracket champion.
- **Round Robin**, generating every participant pairing exactly once, with format-aware completion (every generated match has a terminal outcome) and standings computed by a pure points policy with head-to-head tie-breaking.

## v0.8 — Stabilization, Result Correction & Transaction Hardening

- A dedicated stabilization pass: transaction-boundary audit, a duplicated-materialization-code extraction across bracket-generation format branches, and a documented invariant-soundness finding.
- **Result correction (Single Elimination)** — an owner can correct a completed match's outcome, constrained by whether anything has already propagated downstream: freely corrected if nothing downstream exists yet or the downstream match hasn't started; rejected outright if the downstream match is already in progress or completed.
- A **dual transaction-primitive design** (`withTxN` for plain writes, `withTxEither` for use cases with a real mid-block failure case) formalizing a pattern the codebase had been using inconsistently.

## v0.9 — Tournament Lifecycle & Operations

- **Double Elimination correction lineage** — since Double Elimination's live bracket state gets overwritten the instant a result propagates, correcting a completed DE match requires recomputing the bracket's topology to find what depends on it, rather than trusting live state.
- **Tournament reopening** — a completed tournament can be reopened back to `InProgress` (reason required), after which the same correction rules apply; earlier rounds stay protected by the same downstream-guard.
- **Pause / Resume**, a new `Paused` tournament state reachable only from `InProgress`. Starting a match, recording a result, completing, or correcting a result are all rejected while paused or cancelled — with one deliberate exception: scheduling a match still works while paused, since rescheduling is exactly the administrative action a pause exists to allow.
- **Transaction atomicity and audit-trail hardening** — confirmed a Double Elimination correction that requires deleting an invalid reset match rolls back completely on any mid-transaction failure, and fixed a real decode-ordering bug in tournament history that was silently misrouting certain event types.

## v0.10 — Match Scheduling

- Matches can carry an optional scheduled start time, settable and clearable by the tournament owner while the match hasn't started yet and the tournament isn't completed or cancelled (deliberately allowed while paused).
- An organizer schedule query returns every materialized match for a tournament, timed matches sorted ascending and unscheduled ones last — visible under the same rule as everything else (owner always, public tournaments to any authenticated user, private tournaments owner-only), and deliberately not gated by tournament lifecycle state, since a completed tournament's schedule is still worth viewing.

## v1.0 — API & Frontend

- **An HTTP API** (Scotty) exposing the full organizer and spectator surface over JSON: authentication with bearer tokens, tournament CRUD and lifecycle transitions, participant registration, bracket generation, match actions, and public/anonymous reads for public tournaments.
- **A React + TypeScript frontend**: a public tournament list, organizer registration/login, an organizer dashboard with a create-tournament flow, and a tournament page shared between organizers and spectators — the same page renders organizer controls only for the tournament's owner, everyone else sees the bracket and results.
- Live spectator viewing via polling (every 20 seconds while the tab is visible, stopping once a tournament is completed or cancelled), so a spectator watching a public tournament sees results appear without refreshing.
- Full accessibility and error-handling pass across every page: loading, empty, and error states with retry, screen-reader-appropriate status/alert roles, keyboard-accessible confirmation dialogs, and no color-only status indicators.
- Explicitly out of v1.0: player self-registration or accounts, a frontend for Double Elimination/Round Robin or result correction, production-grade token persistence, and production deployment infrastructure. See `Decisions.md` for the full frozen v1.0 scope.

## Architecture

A layered design, separating pure domain logic from persistence, orchestration, and presentation:

- **Domain** — core types (Tournament, Match, Bracket, Participant, Team, User, TournamentHistory, Scoreable) with no dependency on storage or IO
- **Engine** — pure bracket logic: validation, bracket generation (single elimination, double elimination, round robin), seeding, bye resolution, advancement, materialization, standings
- **Application** — use cases that orchestrate the engine and domain rules against persistence (tournament lifecycle transitions, editing, dashboard, history, accounts, matches, scheduling, correction/reopening, team creation, game-specific registration, score-derived results, standings)
- **Shell** — SQLite persistence layer, file-based CLI sessions, and the HTTP API (`api/Main.hs`, built with Scotty)
- **CLI** — a thin command dispatcher over the use cases; all business logic lives below this layer, not in it
- **`web/`** — a separate React + TypeScript + Vite frontend, talking to the HTTP API only; no business logic is duplicated here

Two cross-cutting rules hold throughout: every mutating use case checks authorization before doing anything else — ownership, Administrator role membership, or tournament visibility — and every lifecycle-sensitive use case validates tournament state before mutating.

## Testing

An hspec integration suite (216 examples) covers the full stack — golden-path lifecycles, bye-path bracket generation across all three formats, error paths, the full lifecycle/editing/history state machine, team creation, CoD/PUBG registration, role-based authorization and audit, score-derived outcomes, Double Elimination (including correction lineage and non-power-of-2 participant counts), Round Robin, result correction, reopening, pause/resume, and scheduling.

Run the suite:

cabal test


## Usage

### Backend (CLI + API)

Build:

cabal build


Run the CLI:

cabal run arenaos -- <command> [arguments]


Most commands are actor-first, taking `<userId>` as the first argument. Session-driven commands, like `dashboard`, act on whoever is currently logged in instead.

Run the API server (listens on port 3000):

cabal run arenaos-api


### Frontend

From the `web/` directory:

npm install
npm run dev


The dev server proxies API requests to the backend, so the API server should be running alongside it.

register-user <username> <email> <password>
login <userId> <password>
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

grant-role <actorId> <userId> <role>
revoke-role <actorId> <userId> <role>
list-roles <userId>
admin-dashboard <actorId>
set-account-status <actorId> <userId> <status>
audit-log <userId>