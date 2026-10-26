-- ArenaOS.Shell.Persistence.SQLite.Schema
-- Stage 1: Infrastructure. No repository code here.
-- verified against GHC
--any assumptions about sqlite-simple's behavour should continue to be verified against the actual library documentation and integration tests
-- environment. Verify against sqlite-simple's actual API before
-- trusting this in the real codebase.
--
-- IMPORTANT: arenaos-schema.sql (frozen v1.0) remains the single
-- source of truth for schema *documentation* -- constraints, DI-10/
-- DI-11 rationale, ADR references, the deferred ADR-FUT-002 note, all
-- live there, not here. This module is the executable form and MUST
-- be kept in exact structural sync with that file. If they diverge,
-- arenaos-schema.sql wins and this file is wrong.
--
-- Split into one statement per Query rather than executing the .sql
-- file as a single script, because sqlite-simple's execute_ runs
-- exactly one statement per call.

{-# LANGUAGE OverloadedStrings #-}

module Shell.Persistence.SQLite.Schema
  ( initializeSchema
  ) where

import Control.Monad (when)
import Database.SQLite.Simple (Connection, Query, execute_, query_)

initializeSchema :: Connection -> IO ()
initializeSchema conn = do
  mapM_ (execute_ conn) statements
  migrateTournamentColumns conn
  migrateRegistrationColumns conn
  migrateHistoryColumns conn
  migrateUserColumns conn
  migratePasswordResets conn
  migrateTeamColumns conn
  migrateBanners conn

-- v0.12: CREATE TABLE IF NOT EXISTS never adds columns to an existing
-- database, so add any missing tournament columns here. Safe on every start.
newTournamentColumns :: [(String, Query)]
newTournamentColumns =
  [ ("game", "ALTER TABLE tournaments ADD COLUMN game TEXT CHECK (game IS NULL OR game IN ('eFootball', 'PubgMobile', 'CallOfDuty', 'Other'))")
  , ("start_time", "ALTER TABLE tournaments ADD COLUMN start_time TEXT")
  , ("prize", "ALTER TABLE tournaments ADD COLUMN prize TEXT")
  , ("prize_kes", "ALTER TABLE tournaments ADD COLUMN prize_kes INTEGER CHECK (prize_kes IS NULL OR prize_kes > 0)")
  , ("description", "ALTER TABLE tournaments ADD COLUMN description TEXT")
  , ("registration_deadline", "ALTER TABLE tournaments ADD COLUMN registration_deadline TEXT")
  , ("require_approval", "ALTER TABLE tournaments ADD COLUMN require_approval INTEGER NOT NULL DEFAULT 0 CHECK (require_approval IN (0, 1))")
  ]

migrateTournamentColumns :: Connection -> IO ()
migrateTournamentColumns conn = do
  cols <- query_ conn "PRAGMA table_info(tournaments)" :: IO [(Int, String, String, Int, Maybe String, Int)]
  let present = [ n | (_, n, _, _, _, _) <- cols ]
  mapM_ (\(n, ddl) -> when (n `notElem` present) (execute_ conn ddl)) newTournamentColumns

-- v0.12: registrations may carry the account that registered itself.
-- Organizer-added players leave user_id NULL.
migrateRegistrationColumns :: Connection -> IO ()
migrateRegistrationColumns conn = do
  cols <- query_ conn "PRAGMA table_info(registrations)" :: IO [(Int, String, String, Int, Maybe String, Int)]
  let present = [ n | (_, n, _, _, _, _) <- cols ]
  when ("user_id" `notElem` present) $
    execute_ conn "ALTER TABLE registrations ADD COLUMN user_id INTEGER REFERENCES users(id)"
  execute_ conn "CREATE UNIQUE INDEX IF NOT EXISTS registrations_tournament_user ON registrations(tournament_id, user_id) WHERE user_id IS NOT NULL"

-- v0.12: optional display name. Existing accounts keep NULL.
migrateUserColumns :: Connection -> IO ()
migrateUserColumns conn = do
  cols <- query_ conn "PRAGMA table_info(users)" :: IO [(Int, String, String, Int, Maybe String, Int)]
  let present = [ n | (_, n, _, _, _, _) <- cols ]
  when ("full_name" `notElem` present) $
    execute_ conn "ALTER TABLE users ADD COLUMN full_name TEXT"

-- v0.12: password reset tokens. Only a hash of the secret is stored.
migratePasswordResets :: Connection -> IO ()
migratePasswordResets conn =
  execute_ conn "CREATE TABLE IF NOT EXISTS password_resets (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id), secret_hash TEXT NOT NULL, expires_at INTEGER NOT NULL, used_at INTEGER)"

-- v0.12: history events carry the time they happened. Rows written before
-- this column existed stay NULL and are left out of the activity feed.
migrateHistoryColumns :: Connection -> IO ()
migrateHistoryColumns conn = do
  cols <- query_ conn "PRAGMA table_info(tournament_history)" :: IO [(Int, String, String, Int, Maybe String, Int)]
  let present = [ n | (_, n, _, _, _, _) <- cols ]
  when ("occurred_at" `notElem` present) $
    execute_ conn "ALTER TABLE tournament_history ADD COLUMN occurred_at TEXT"

-- v0.12: the account that created a team. Older teams keep NULL (organizer-only).
migrateTeamColumns :: Connection -> IO ()
migrateTeamColumns conn = do
  cols <- query_ conn "PRAGMA table_info(teams)" :: IO [(Int, String, String, Int, Maybe String, Int)]
  let present = [ n | (_, n, _, _, _, _) <- cols ]
  when ("owner_user_id" `notElem` present) $
    execute_ conn "ALTER TABLE teams ADD COLUMN owner_user_id INTEGER REFERENCES users(id)"

-- v0.12: tournament banner pictures (JPEG bytes, one per tournament).
migrateBanners :: Connection -> IO ()
migrateBanners conn =
  execute_ conn "CREATE TABLE IF NOT EXISTS tournament_banners (tournament_id INTEGER PRIMARY KEY REFERENCES tournaments(id), image BLOB NOT NULL, updated_at TEXT NOT NULL)"

statements :: [Query]
statements =
  [ "CREATE TABLE IF NOT EXISTS players ( \
    \  id   INTEGER PRIMARY KEY, \
    \  name TEXT NOT NULL UNIQUE \
    \)"

  , "CREATE TABLE IF NOT EXISTS teams ( \
    \  id                 INTEGER PRIMARY KEY, \
    \  name               TEXT NOT NULL UNIQUE, \
    \  captain_player_id  INTEGER NOT NULL REFERENCES players(id) \
    \)"
    -- DI-08 deliberately unenforced here -- see arenaos-schema.sql
    -- comment on the removed trigger. Application-layer concern.

  , "CREATE TABLE IF NOT EXISTS team_members ( \
    \  team_id   INTEGER NOT NULL REFERENCES teams(id), \
    \  player_id INTEGER NOT NULL REFERENCES players(id), \
    \  PRIMARY KEY (team_id, player_id) \
    \)"

  , "CREATE TABLE IF NOT EXISTS participants ( \
    \  id        INTEGER PRIMARY KEY, \
    \  kind      TEXT NOT NULL CHECK (kind IN ('Individual', 'Squad')), \
    \  player_id INTEGER REFERENCES players(id), \
    \  team_id   INTEGER REFERENCES teams(id), \
    \  CHECK ( \
    \    (kind = 'Individual' AND player_id IS NOT NULL AND team_id IS NULL) OR \
    \    (kind = 'Squad'      AND team_id   IS NOT NULL AND player_id IS NULL) \
    \  ) \
    \)"

  , "CREATE TABLE IF NOT EXISTS tournaments ( \
    \  id                 INTEGER PRIMARY KEY, \
    \  name               TEXT NOT NULL, \
    \  organizer_name     TEXT NOT NULL, \
    \  owner_id           INTEGER NOT NULL REFERENCES users(id), \
    \  format             TEXT NOT NULL CHECK (format IN \
    \                        ('SingleElimination', 'DoubleElimination', 'RoundRobin')), \
    \  state              TEXT NOT NULL CHECK (state IN \
    \                        ('Draft', 'Published', 'RegistrationOpen', 'RegistrationClosed', \
    \                         'InProgress', 'Paused', 'Completed', 'Cancelled')), \
    \  visibility         TEXT NOT NULL CHECK (visibility IN ('Public', 'Private')), \
    \ third_place_match INTEGER NOT NULL DEFAULT 0 CHECK (third_place_match IN (0, 1)), \
    \  participant_mode   TEXT NOT NULL DEFAULT 'IndividualOnly' \
    \                        CHECK (participant_mode IN ('IndividualOnly', 'SquadOnly')), \
    \  max_participants   INTEGER NOT NULL CHECK (max_participants >= 2), \
    \  bracket_id         INTEGER REFERENCES brackets(id), \
    \  game               TEXT CHECK (game IS NULL OR game IN ('eFootball', 'PubgMobile', 'CallOfDuty', 'Other')), \
    \  start_time         TEXT, \
    \  prize              TEXT, \
    \  require_approval   INTEGER NOT NULL DEFAULT 0 CHECK (require_approval IN (0, 1)) \
    \)"
    -- Circular FK with brackets.tournament_id below -- SQLite allows
    -- the forward reference at CREATE TABLE time; the insert-order
    -- constraint (tournament first, bracket_id NULL) is enforced by
    -- TournamentRepository/BracketRepository logic, not by the DDL.
    -- participant_mode: fixed at creation (no update path). Existing databases
    -- need a one-off: ALTER TABLE tournaments ADD COLUMN participant_mode TEXT
    -- NOT NULL DEFAULT 'IndividualOnly' CHECK (participant_mode IN
    -- ('IndividualOnly','SquadOnly')). CREATE TABLE IF NOT EXISTS will not add it.

  , "CREATE TABLE IF NOT EXISTS registrations ( \
    \  id             INTEGER PRIMARY KEY, \
    \  tournament_id  INTEGER NOT NULL REFERENCES tournaments(id), \
    \  participant_id INTEGER NOT NULL REFERENCES participants(id), \
    \  status         TEXT NOT NULL CHECK (status IN ('Confirmed')), \
    \  UNIQUE (tournament_id, participant_id) \
    \)"
    -- DI-10.

  , "CREATE TABLE IF NOT EXISTS brackets ( \
  \  id            INTEGER PRIMARY KEY, \
  \  tournament_id INTEGER NOT NULL REFERENCES tournaments(id), \
  \  gf1_node_id   INTEGER REFERENCES bracket_nodes(id), \
  \  reset_node_id INTEGER REFERENCES bracket_nodes(id), \
  \ third_place_node_id INTEGER REFERENCES bracket_nodes(id), \
  \  CHECK ((gf1_node_id IS NULL) = (reset_node_id IS NULL)) \
  \)"

  , "CREATE TABLE IF NOT EXISTS bracket_nodes ( \
    \  id         INTEGER PRIMARY KEY, \
    \  bracket_id INTEGER NOT NULL REFERENCES brackets(id), \
    \  round      INTEGER NOT NULL, \
    \  stage      TEXT NOT NULL CHECK (stage IN ('Winners', 'Losers')), \
    \  slot_a_type            TEXT NOT NULL CHECK (slot_a_type IN \
    \                            ('Filled', 'AwaitingWinner', 'AwaitingLoser', 'Bye')), \
    \  slot_a_participant_id  INTEGER REFERENCES participants(id), \
    \  slot_a_node_id         INTEGER REFERENCES bracket_nodes(id), \
    \  slot_b_type            TEXT NOT NULL CHECK (slot_b_type IN \
    \                            ('Filled', 'AwaitingWinner', 'AwaitingLoser', 'Bye')), \
    \  slot_b_participant_id  INTEGER REFERENCES participants(id), \
    \  slot_b_node_id         INTEGER REFERENCES bracket_nodes(id), \
    \  CHECK ((slot_a_type = 'Filled') = (slot_a_participant_id IS NOT NULL)), \
    \  CHECK ((slot_b_type = 'Filled') = (slot_b_participant_id IS NOT NULL)) \
    \)"

  

  , " CREATE TABLE IF NOT EXISTS users (\
     \ id            INTEGER PRIMARY KEY AUTOINCREMENT,\
     \ username      TEXT NOT NULL UNIQUE,\
     \ email         TEXT NOT NULL UNIQUE,\
     \ password_hash TEXT NOT NULL,\
     \ account_status TEXT NOT NULL DEFAULT 'Active' CHECK (account_status IN ('Active', 'Suspended', 'Deactivated'))\
      \)"

  , "CREATE TABLE IF NOT EXISTS user_roles ( \
    \  user_id INTEGER NOT NULL REFERENCES users(id), \
    \  role    TEXT NOT NULL CHECK (role IN ('Administrator')), \
    \  PRIMARY KEY (user_id, role) \
    \)"


  , "CREATE TABLE IF NOT EXISTS tournament_history (\
    \id                  INTEGER PRIMARY KEY AUTOINCREMENT,\
    \tournament_id       INTEGER NOT NULL REFERENCES tournaments(id),\
    \event_type          TEXT NOT NULL,\
    \cancellation_reason TEXT,\
    \changed_field       TEXT,\
    \CHECK (\
    \(event_type != 'TournamentCancelled' OR cancellation_reason IS NOT NULL) AND\
    \(event_type != 'ConfigurationChanged' OR changed_field IS NOT NULL) AND\
    \(event_type NOT IN ('TournamentCancelled','ConfigurationChanged') OR TRUE))\   
    \)"

  , "CREATE TABLE IF NOT EXISTS audit_log ( \
    \  id              INTEGER PRIMARY KEY AUTOINCREMENT, \
    \  actor_id        INTEGER NOT NULL REFERENCES users(id), \
    \  entity_id       INTEGER NOT NULL REFERENCES users(id), \
    \  operation       TEXT NOT NULL CHECK (operation IN \
    \                    ('RoleGranted', 'RoleRevoked', 'AccountStatusChanged')), \
    \  role            TEXT CHECK (role IN ('Administrator')), \
    \  previous_status TEXT CHECK (previous_status IN ('Active', 'Suspended', 'Deactivated')), \
    \  new_status      TEXT CHECK (new_status IN ('Active', 'Suspended', 'Deactivated')), \
    \  occurred_at     TEXT NOT NULL, \
    \  CHECK (operation NOT IN ('RoleGranted', 'RoleRevoked') OR role IS NOT NULL), \
    \  CHECK (operation != 'AccountStatusChanged' \
    \         OR (previous_status IS NOT NULL AND new_status IS NOT NULL)) \
    \)"
  , "CREATE TABLE IF NOT EXISTS efootball_scores ( \
   \  match_id            INTEGER PRIMARY KEY REFERENCES matches(id), \
   \  competitor_a_score  INTEGER NOT NULL CHECK (competitor_a_score >= 0), \
   \  competitor_b_score  INTEGER NOT NULL CHECK (competitor_b_score >= 0) \
   \)"

  , "CREATE TABLE IF NOT EXISTS matches ( \
    \  id                            INTEGER PRIMARY KEY, \
    \  tournament_id                 INTEGER NOT NULL REFERENCES tournaments(id), \
    \  bracket_id                    INTEGER NOT NULL REFERENCES brackets(id), \
    \  bracket_node_id               INTEGER NOT NULL REFERENCES bracket_nodes(id), \
    \  competitor_a_participant_id   INTEGER NOT NULL REFERENCES participants(id), \
    \  competitor_b_participant_id   INTEGER NOT NULL REFERENCES participants(id), \
    \  status                        TEXT NOT NULL CHECK (status IN \
    \                                   ('Scheduled', 'InProgress', 'Completed', 'Cancelled')), \
    \  outcome_type                  TEXT CHECK (outcome_type IN \
    \                                   ('Winner', 'Draw', 'Forfeit', 'Disqualification', 'NoContest')), \
    \  outcome_participant_id        INTEGER REFERENCES participants(id), \
    \  scheduled_start                TEXT, \
    \  CHECK ((status = 'Completed') = (outcome_type IS NOT NULL)), \
    \  CHECK (outcome_type NOT IN ('Winner', 'Forfeit', 'Disqualification') \
    \         OR outcome_participant_id IS NOT NULL), \
    \  CHECK (outcome_type NOT IN ('Draw', 'NoContest') \
    \         OR outcome_participant_id IS NULL), \
    \  CHECK (competitor_a_participant_id <> competitor_b_participant_id) \
    \)"
    -- DI-06, DI-11.
    -- v0.10: scheduled_start is nullable TEXT, canonical UTC ISO 8601
    -- (YYYY-MM-DDTHH:MM:SSZ). No DB-level format CHECK -- canonicality
    -- is enforced entirely by MatchRepository's explicit encode/decode
    -- codec (isolated divergence from sqlite-simple's default UTCTime
    -- instance, which audit_log.occurred_at still uses unchanged).
    
  

  , "CREATE INDEX IF NOT EXISTS idx_registrations_tournament ON registrations(tournament_id)"
  , "CREATE INDEX IF NOT EXISTS idx_matches_bracket          ON matches(bracket_id)"
  , "CREATE INDEX IF NOT EXISTS idx_nodes_bracket             ON bracket_nodes(bracket_id)"
  , "CREATE INDEX IF NOT EXISTS idx_team_members_team         ON team_members(team_id)"
  , "CREATE UNIQUE INDEX IF NOT EXISTS idx_teams_name_nocase ON teams(name COLLATE NOCASE)"
  , "CREATE TABLE IF NOT EXISTS bracket_links ( \
    \  node_id        INTEGER PRIMARY KEY REFERENCES bracket_nodes(id), \
    \  bracket_id     INTEGER NOT NULL REFERENCES brackets(id), \
    \  winner_node_id INTEGER REFERENCES bracket_nodes(id), \
    \  winner_slot    TEXT CHECK (winner_slot IN ('A', 'B')), \
    \  loser_node_id  INTEGER REFERENCES bracket_nodes(id), \
    \  loser_slot     TEXT CHECK (loser_slot IN ('A', 'B')), \
    \  CHECK ((winner_node_id IS NULL) = (winner_slot IS NULL)), \
    \  CHECK ((loser_node_id IS NULL) = (loser_slot IS NULL)) \
    \)"
  , "CREATE INDEX IF NOT EXISTS idx_links_bracket ON bracket_links(bracket_id)"
  , "CREATE TABLE IF NOT EXISTS join_requests ( \
    \  id            INTEGER PRIMARY KEY, \
    \  tournament_id INTEGER NOT NULL REFERENCES tournaments(id), \
    \  user_id       INTEGER NOT NULL REFERENCES users(id), \
    \  status        TEXT NOT NULL CHECK (status IN ('Pending', 'Approved', 'Declined')), \
    \  UNIQUE (tournament_id, user_id) \
    \)"
  , "CREATE TABLE IF NOT EXISTS notifications ( \
    \  id            INTEGER PRIMARY KEY, \
    \  user_id       INTEGER NOT NULL REFERENCES users(id), \
    \  kind          TEXT NOT NULL CHECK (kind IN \
    \                  ('JoinRequested', 'RequestApproved', 'RequestDeclined', 'TournamentStarted')), \
    \  tournament_id INTEGER NOT NULL REFERENCES tournaments(id), \
    \  detail        TEXT, \
    \  created_at    TEXT NOT NULL, \
    \  read_at       TEXT \
    \)"
  , "CREATE INDEX IF NOT EXISTS idx_notifications_user ON notifications(user_id)"
  , "CREATE TABLE IF NOT EXISTS user_avatars ( \
    \  user_id    INTEGER PRIMARY KEY REFERENCES users(id), \
    \  image      BLOB NOT NULL, \
    \  updated_at TEXT NOT NULL \
    \)"
  ]
