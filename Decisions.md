# ArenaOS — Decisions

This document records the architectural and design decisions behind ArenaOS as it stands at v1.0 — what was chosen, and why. It is not a change log or a session transcript; entries here are locked decisions, verified against real code, not proposals or abandoned ideas.

---

## 1. Architecture

ArenaOS is built as four pieces sharing one Haskell core, only two of which are independently deployable:

- **Haskell core** (`Domain` → `Engine` → `Application` → `Shell`) — the tournament engine itself: lifecycle, bracket generation, match advancement, auth, persistence. Not deployed on its own; consumed by both the CLI and the API. Dependencies point inward only; nothing in `Domain` or `Engine` knows about SQLite, HTTP, or the CLI.
- **CLI** (`app/Main.hs`) — a thin command dispatcher over the same use cases the API uses.
- **HTTP API** (`api/Main.hs`, Scotty + Aeson) — a second, independent Shell-layer consumer of the same `Application` use cases as the CLI, deployable on its own. Chosen over a heavier framework because ArenaOS's API surface is a fixed, known set of routes with no need for the machinery a larger framework brings.
- **Frontend** (`web/`, React + TypeScript + Vite) — a separate, independently deployable application, communicating with the API exclusively over JSON. It has no access to and does not duplicate any business logic; every rule the frontend appears to enforce (state gating, capacity, visibility) is enforced again, authoritatively, by the API.

## 2. Authentication

- **Tokens are real, opaque, bearer tokens** — 32 bytes of entropy, hex-encoded, generated per login and held in an in-memory `Map Text UserId` inside the API process (`envTokens`). Not JWTs; nothing is decoded client-side.
- **`currentUser`** resolves a request's `Authorization: Bearer <token>` header to a `UserId` by table lookup, additionally requiring the account's `AccountStatus` be `Active` — a suspended or deactivated user's still-live token is rejected even though the token itself hasn't expired.
- Every mutating API route authorizes against `UserId`, not the token directly — the token is purely a lookup key. This keeps the API's authorization model identical to the CLI's own actor-first `UserId` convention.
- **Participant registration is organizer-only in v1.** There is no self-registration and no `User`-to-`Player` link. A tournament's organizer adds participants by name; those participants are not accounts and cannot log in.
- **v1's scope is organizers and spectators only.** Organizers register, log in, and manage their own tournaments. Spectators need no account at all — public tournament reads work anonymously. Player accounts, and any relationship between a `User` and the `Player`s they've competed as, are explicitly out of scope for v1.

## 3. API Conventions

- **Every error response is a consistent JSON shape**: `{ "error": { "code", "message", "details" } }`, with an HTTP status chosen per error category (400 for validation/bad input, 401 for auth, 403 for authorization, 404 for not-found, 409 for state conflicts, 500 for anything unexpected).
- **`code` is a stable, machine-readable string** (`VALIDATION_FAILED`, `UNAUTHENTICATED`, `NOT_FOUND`, `BRACKET_REQUIRED`, etc.) — the frontend branches on `code`, never on `message` text, since `message` is meant for a human to read, not for control flow.
- **`VALIDATION_FAILED`** is the one code that additionally carries `details.field` naming which input was wrong, so the frontend can place the error next to the right form field. Not every 4xx has a `field` — conflict errors like `USERNAME_TAKEN`/`EMAIL_TAKEN` are 409s with no field, since they're not a malformed request, they're a state conflict discovered only after otherwise-valid input was checked against existing data.
- **`401 UNAUTHENTICATED` and `401 INVALID_CREDENTIALS` are deliberately different codes for different situations**, both surfaced as plain 401s but meaning opposite things to the frontend: `UNAUTHENTICATED` means a token that was sent is missing, dead, or belongs to a suspended account — the frontend clears its stored token and signs the user out. `INVALID_CREDENTIALS` means a login attempt failed — nobody was signed in to begin with, so nothing gets cleared; the login form just shows the error.
- **No exception detail or `show err` text is ever put in an HTTP response.** Internal/unexpected failures map to a generic `INTERNAL_ERROR` with a fixed message; the real exception is logged server-side (`hPutStrLn stderr`), never sent to the client.
- **A 409 response means "the state changed under you" and is handled by refetching, not by trying to patch local state.** The frontend never attempts optimistic updates against tournament or match state — every mutation is followed by a full reload of the affected view.

## 4. Frontend Architecture

- **React + TypeScript, deliberately minimal.** Function components, `useState`/`useEffect`, `react-router`, and direct `fetch`-based API calls. No Redux, no Zustand, no other state library.
- **`AuthContext` is the one piece of state held outside individual components** — `{ id, username } | null`, plus `expired`/`dismissExpired`. Everything else is local component state; there was no case in v1 that needed shared state beyond auth.
- **Native `<dialog>` for all confirmations**, not a hand-rolled modal — `showModal()`/`close()` give focus trapping and Escape-to-cancel for free, wired to the same busy/error handling every other form in the app uses.
- **The API layer is a separate module (`api.ts`) that components never bypass.** Components call typed functions (`createTournament`, `startMatch`, etc.) that live in `lib/tournamentActions.ts` and `auth/authActions.ts`; nothing constructs a `fetch` call directly inside a component.
- **Every API response is runtime-validated against a Zod schema** before the app trusts it as typed data (`model.ts`). This was a deliberate choice over trusting TypeScript's compile-time types alone — the API is a separate process that can drift from what the frontend expects, and a malformed or unexpected response fails loudly (`BAD_RESPONSE`) rather than silently producing `undefined` deep inside a component.

## 5. Tournament UI

- **Bracket layout**: one column per round, left to right, round labels (`Final`, `Semifinals`, `Quarterfinals`, `Round N`) computed from round number and total rounds. No connector lines between cards. Horizontal scroll on narrow screens rather than any responsive re-layout of the bracket itself.
- **Byes are ordinary nodes**, not hidden or specially laid out — a bye's match-status text reads "Bye" rather than "Waiting for players," which is the only bye-specific UI behavior. Verified against both a clean power-of-2 bracket and a non-power-of-2 bracket with real byes.
- **The organizer action set is a fixed table keyed on tournament state**, not a set of always-visible buttons with disabled states: `Draft` → Publish/Cancel; `Published` → Open registration/Cancel; `RegistrationOpen` → Add participant/Close registration/Cancel; `RegistrationClosed` → Generate bracket/Start tournament/Cancel; `InProgress` → per-match Start/Choose winner, Complete once the final resolves, Cancel; `Paused`/`Completed`/`Cancelled` → no actions. Match actions are only ever shown while `InProgress`.
- **Every mutation refetches** rather than optimistically updating, and every action button disables itself while its own request is in flight.
- **Three actions require an explicit confirmation dialog**: Cancel (reason required, non-blank), Close registration, and Record result (explicit winner confirmation) — chosen because each is either destructive or hard/impossible to reverse through the current API.
- **Result correction has no frontend in v1.** The backend supports it; v1's UI treats every recorded result as permanent.
- **Live viewing polls every 20 seconds**, only while the browser tab is visible, and stops once a tournament reaches `Completed` or `Cancelled`. Returning to a hidden tab triggers an immediate refetch rather than waiting for the next tick. A failed poll keeps the last good data on screen with a "couldn't refresh" notice rather than blanking the view.

## 6. Explicitly Deferred (out of v1 scope)

- Player self-registration, player accounts, and any `User`-to-`Player` link
- **The v1 create/manage workflow is Single Elimination only.** The backend supports Double Elimination and Round Robin, and the tournament page can already render a backend-produced bracket in either format — but v1's create form only offers Single Elimination, and there is no frontend for DE-specific actions (grand final/reset) or RR standings.
- A frontend for result correction or tournament reopening (the backend supports both)
- **No frontend scheduling UI.** The backend supports setting and reading a match's scheduled time; no part of v1's UI exposes it.
- Server-push (SSE/WebSockets) — v1 uses polling only
- Team/game-specific platform features (Call of Duty, PUBG, or any other game-specific registration flow) in the frontend. **ArenaOS v1 is tournament-engine complete, not game-platform complete** — the engine can run a tournament end to end, but the product layer for specific games, teams, and their registration/eligibility rules is deliberately later.
- Production-grade token persistence or expiry — see Known Limitations below
- Production deployment infrastructure

## 7. Known v1 Limitations

- **Tokens are held in an in-memory `Map` inside the API process.** A server restart invalidates every active session; there is no persistence, refresh mechanism, or expiry. Accepted as a v1 tradeoff, not a bug — the frontend detects a dead token via the normal `UNAUTHENTICATED` path and prompts a re-login, with no special-casing needed for the restart case.
- **A single global lock (`MVar ()`) serializes every write through the API**, one connection to one SQLite file. This is correct and simple for a single-organizer, low-concurrency use case, but is a real scalability ceiling, not something that's been load-tested or is expected to hold under concurrent write-heavy use.
- **No HTTPS, no CORS hardening beyond local dev, no rate limiting.** ArenaOS v1 is built and verified as a local/dev-served application; none of this has been addressed for a public deployment.