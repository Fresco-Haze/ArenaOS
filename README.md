# ArenaOS

**Author:** Jeremiah

A game-agnostic tournament management platform, built in pure Haskell.

ArenaOS handles the backend logic for running tournament brackets — creating a tournament, registering participants, generating the bracket, and automatically advancing winners through each round as match results come in — with full accounts, ownership, lifecycle management, and an audit trail of everything that happens to a tournament.

**Status: v0.7**

Seven milestones in, driven entirely through a CLI:

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

## v0.6 — Administrator Roles, Authorization & Audit Trail

- **A role-based authorization mechanism**, added alongside the existing ownership-based one rather than replacing or generalizing it. `Role` currently has a single constructor, `Administrator` — deliberately not modeled as a mirror of every business responsibility in the system (Organizer, Player, Team Captain remain expressed through existing domain relationships — tournament ownership, team membership — not persisted role rows). New roles get added only when a concrete need for independent, cross-resource authority actually arises, the same evidence-first discipline v0.5 applied to registration abstraction.
- **`grantRole` / `revokeRole`**, non-idempotent by design (matching every other relationship-establishing operation in ArenaOS — granting an already-held role, or revoking one that isn't held, is rejected rather than silently accepted). An existing Administrator can grant or revoke Administrator status from another user; the system refuses any revocation that would leave the platform with zero Administrators. The very first Administrator is established outside the application entirely, by direct database seeding — there's no in-app bootstrap command, and none was added speculatively.
- **Administrative retrofits to two existing capabilities**: `set-account-status` now requires an authorized actor (previously callable by anyone, against any account) and rejects unauthorized attempts before ever checking whether the target exists. A new **Administrator dashboard** provides an unfiltered, platform-wide view of every tournament regardless of owner, distinct from the existing owner-scoped Organizer dashboard — both now share a single underlying aggregation (`TournamentOverview`), extracted once a genuine second consumer existed, rather than duplicated or built as one dashboard trying to serve two audiences.
- **An audit trail for security-sensitive administrative actions** — every role grant, role revocation, and account status change is recorded with actor, affected user, operation, and a real UTC timestamp. Account status changes record both the previous and new value, not just the new one. Audit records are append-only, and a failed audit write rolls back the administrative action it would have recorded — an action that can't be logged doesn't happen.
- Deliberately **not** built: audit coverage for administrative dashboard reads (read access wasn't judged clearly "security-sensitive" under the frozen requirements, and the frozen text doesn't say either way); tournament ownership transfer and other administrative intervention workflows (explicitly out of scope per the underlying requirement itself, not an oversight); any general-purpose role-assignment framework beyond what `Administrator` alone currently needs.

## v0.7 — Match & Competition Semantics: Score-Derived Outcomes, Double Elimination, Round Robin

- **Score-derived match outcomes.** A new `Scoreable` typeclass and a concrete `EFootballScore` type (goal count for one competitor, validated non-negative via a smart constructor) let a game-specific result derive the generic `MatchOutcome` rather than requiring it to be entered directly. `recordEFootballResult` compares both competitors' scores and delegates into the existing match-result pipeline for authorization, lifecycle validation, and advancement — the generic `MatchOutcome`/`Match` types themselves stay completely untouched by any game-specific concept. A real atomicity bug was found by the test suite (a score could persist even when the underlying result recording failed, since a returned `Left` doesn't roll back a transaction the way a thrown exception does) and fixed by reordering writes so nothing persists until success is already confirmed, not by forcing an exception. Penalty shootouts, extra time, and aggregate/two-leg scoring are all deliberately out of scope — no frozen requirement calls for them yet.
- **Draw and NoContest**, previously silent no-ops that advanced nobody, now explicitly rejected for elimination formats (`Single`/`DoubleElimination`) at the same validation tier as an invalid competitor, since a knockout bracket has no way to progress without a winner. This rule was later made format-aware (see below) once Round Robin needed the opposite behavior.
- **`UnsupportedFormat` guard.** `TournamentFormat` was previously stored but never actually checked by bracket generation — generating a bracket for an unimplemented format now fails loudly and explicitly instead of silently producing the wrong topology.
- **Double Elimination**, a full grand-final-with-bracket-reset implementation covering both power-of-2 and non-power-of-2 participant counts. A dedicated Losers Bracket topology with round-alternating pure/drop-in structure and cross-seeding, a Grand Final node with a fixed slot convention (Winners-origin vs. Losers-origin), and a reset match that only materializes if the Losers Bracket champion actually upsets the Winners Bracket champion in the Grand Final. Byes are handled correctly at every stage, including a genuine bye that only forms mid-tournament as results come in (a Losers Bracket node that starts out awaiting a real match's loser and only becomes bye-shaped once that match concludes) — automatic bye advancement now re-runs on every match completion, not only at bracket-generation time.
- **Round Robin**, generating every participant pairing exactly once (`n(n-1)/2` matches, single round-robin only — double round-robin and round-by-round scheduling are both deliberately deferred as separate, unimplemented problems). Draw and NoContest are legitimate terminal outcomes here, since nothing in a round-robin format needs to advance. Tournament completion is redefined per format: elimination formats determine a champion from the final bracket node, Round Robin instead completes once every generated match has a terminal outcome — these had silently shared one code path keyed on the presence of a Grand-Final node, which happened to also match Round Robin's shape and would have produced an incorrect completion check; this is now dispatched explicitly on format.
- **Round Robin standings**, computed by a pure, fully generic points policy (Win 3 / Draw 1 each / Loss 0, Forfeit and Disqualification treated the same as a normal win-or-loss with no cross-match consequences, NoContest scoring 0 for both sides — deliberately not treated as a draw, preserving the distinction between a contested even result and no legitimate result at all) with ties broken by a single head-to-head pass restricted to matches played only among the currently tied group. A perfect three-way (or larger) cycle is explicitly left unresolved after that pass, falling back to a stable but arbitrary order — deeper tiers (score/goal differential, iterative re-narrowing of a partial sub-tie) are deferred, not silently assumed away. Standings are readable mid-tournament, not just after completion. A new visibility-based read authorization rule was introduced specifically for this — public tournaments' standings are viewable by any authenticated user, private tournaments' only by their owner — distinct from every other authorization check in ArenaOS, which had so far been ownership- or role-based only, never visibility-based.
- Deliberately **not** built: N-way match support and per-team ranked scoring (the PUBG-shaped gap first documented in v0.5, still not forced by concrete demand); any game beyond eFootball wired to score-derived outcomes; a CLI command exposing Round Robin standings (the use case exists and is tested, but isn't yet reachable from the command dispatcher).

Every decision above that wasn't directly specified by ArenaOS's frozen requirements is recorded as an explicit judgment call in the project's architecture decisions, not presented as something the requirements dictated.

## Architecture

A layered design, separating pure domain logic from persistence and orchestration:

- **Domain** — core types (Tournament, Match, Bracket, Participant, Team, User, TournamentHistory, Scoreable) with no dependency on storage or IO
- **Engine** — pure bracket logic: validation, bracket generation (single elimination, double elimination, round robin), seeding, bye resolution, advancement, materialization, standings
- **Application** — use cases that orchestrate the engine and domain rules against persistence (tournament lifecycle transitions, editing, dashboard, history, accounts, matches, team creation, game-specific registration, score-derived results, standings)
- **Shell** — SQLite persistence layer, plus file-based CLI sessions
- **CLI** — a thin command dispatcher over the use cases; all business logic lives below this layer, not in it

Two cross-cutting rules hold throughout: every mutating use case checks authorization before doing anything else — ownership, Administrator role membership, or (new in v0.7) tournament visibility, all via `Application.Internal.Authorization` — and every lifecycle-sensitive use case validates tournament state before mutating (`Application.Internal.LifecycleTransition`).

## Testing

An hspec integration suite (93 examples) covers the full stack — golden-path lifecycles, bye-path bracket generation, error paths (wrong state, non-owner, invalid transitions), the full v0.3 lifecycle/editing/history state machine, team creation, CoD/PUBG registration, v0.6's role-based authorization/grant-revoke/audit-trail behavior, and v0.7's score-derived outcomes (including the atomicity fix), Double Elimination across both power-of-2 and non-power-of-2 participant counts, and Round Robin's generation, format-aware result recording, completion, and standings (including its tie-breaking behavior).



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

grant-role <actorId> <userId> <role>
revoke-role <actorId> <userId> <role>
list-roles <userId>
admin-dashboard <actorId>
set-account-status <actorId> <userId> <status>
audit-log <userId>