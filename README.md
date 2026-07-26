# ArenaOS

**Author:** Jeremiah

A game-agnostic tournament management platform, built in pure Haskell.

ArenaOS handles the backend logic for running tournament brackets — creating
a tournament, registering participants, generating the bracket, and
automatically advancing winners through each round as match results come in.

## Status: v0.1

v0.1 proves the core engine works end-to-end, driven through a CLI:

- Create a tournament
- Register participants
- Generate a single-elimination bracket
- Play through matches (start → record result)
- Automatic advancement of winners through each round, including bye
  handling for uneven participant counts
- Complete the tournament once a champion is determined

This version deliberately excludes accounts and authentication — the goal
was to get the engine itself right first. Accounts/auth are planned for
v0.2.

## Architecture

A layered design, separating pure domain logic from persistence and
orchestration:

- **Domain** — core types (Tournament, Match, Bracket, Participant) with no
  dependency on storage or IO
- **Engine** — pure bracket logic: validation, bracket generation, seeding,
  bye resolution, advancement, materialization
- **Application** — use cases that orchestrate the engine against
  persistence (CreateTournament, RegisterParticipant, GenerateBracket,
  StartMatch, RecordMatchResult, CompleteTournament)
- **Shell** — SQLite persistence layer
- **CLI** — a thin command dispatcher over the use cases

## Testing

An integration test suite (hspec) covers:

- The full golden-path lifecycle (4 participants, straight through to a
  completed tournament)
- A bye-path scenario (3 participants, exercising bye resolution)
- Error paths — rejecting an already-started match, a result recorded
  before a match starts, a winner who isn't a competitor in the match, and
  completing a tournament with matches still pending

## Usage

Build:cabal build

Run the CLI:
cabal run arenaos -- create-tournament "My Cup" "Organizer Name" 4
cabal run arenaos -- register 1 Alice
cabal run arenaos -- register 1 Bob
cabal run arenaos -- register 1 Carol
cabal run arenaos -- register 1 Dave
cabal run arenaos -- generate-bracket 1
cabal run arenaos -- list-matches 1
cabal run arenaos -- start-match 1
cabal run arenaos -- record-result 1 A
cabal run arenaos -- complete-tournament 1

Full command reference:
create-tournament <name> <organizer> <maxParticipants>
register <tournamentId> <playerName>
generate-bracket <tournamentId>
list-matches <bracketId>
start-match <matchId>
record-result <matchId> <A|B>
complete-tournament <tournamentId>

Run tests:
cabal test
