{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}

module Shell.Persistence.SQLite.SubstitutionRepository () where

import Control.Exception (throwIO)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.String (fromString)
import Database.SQLite.Simple (Only(..), Query, execute, query, lastInsertRowId)

import Domain.Ids (UserId(..), TournamentId(..))
import Domain.Participant (TeamName(..))
import Domain.Substitution (Substitution(..), SubstitutionStatus(..))
import Shell.Persistence.Port (SubstitutionRepository(..))
import Shell.Persistence.SQLite.Connection (SQLiteEnv(..), SQLiteM)
import Shell.Persistence.SQLite.Error (PersistenceError(..))

statusToText :: SubstitutionStatus -> String
statusToText SubPending  = "Pending"
statusToText SubApproved = "Approved"
statusToText SubDeclined = "Declined"

textToStatus :: String -> IO SubstitutionStatus
textToStatus "Pending"  = pure SubPending
textToStatus "Approved" = pure SubApproved
textToStatus "Declined" = pure SubDeclined
textToStatus other =
  throwIO (StorageFailure ("Unknown substitution status in storage: " ++ other))

type Row = (Int, String, Int, String, Int, Int, String)

toSub :: Row -> IO Substitution
toSub (i, team, tid, out, inU, by, st) = do
  s <- textToStatus st
  pure Substitution
    { subId          = i
    , subTeam        = TeamName team
    , subTournament  = TournamentId tid
    , subOutPlayer   = out
    , subInUser      = UserId inU
    , subRequestedBy = UserId by
    , subStatus      = s
    }

selectBase :: String
selectBase =
  "SELECT s.id, t.name, s.tournament_id, s.out_player, s.in_user_id, s.requested_by, s.status \
  \FROM team_substitutions s JOIN teams t ON t.id = s.team_id "

instance SubstitutionRepository SQLiteM where

  listTournamentIdsForTeam :: TeamName -> SQLiteM [TournamentId]
  listTournamentIdsForTeam (TeamName tname) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn
        "SELECT DISTINCT r.tournament_id FROM registrations r \
        \JOIN participants p ON p.id = r.participant_id \
        \JOIN teams t ON t.id = p.team_id \
        \WHERE t.name = ? COLLATE NOCASE"
        (Only tname)
       :: IO [Only Int])
    pure [ TournamentId n | Only n <- rows ]

  createSubstitution :: TeamName -> TournamentId -> String -> UserId -> UserId -> SQLiteM Int
  createSubstitution (TeamName tname) (TournamentId tid) outP (UserId inU) (UserId by) = do
    conn <- asks envConnection
    liftIO $ do
      execute conn
        "INSERT INTO team_substitutions (team_id, tournament_id, out_player, in_user_id, requested_by, status, created_at) \
        \SELECT id, ?, ?, ?, ?, 'Pending', strftime('%Y-%m-%dT%H:%M:%SZ', 'now') FROM teams WHERE name = ? COLLATE NOCASE"
        (tid, outP, inU, by, tname)
      n <- lastInsertRowId conn
      pure (fromIntegral n)

  listSubstitutionsForTournament :: TournamentId -> SQLiteM [Substitution]
  listSubstitutionsForTournament (TournamentId tid) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn (fromString' (selectBase ++ "WHERE s.tournament_id = ? ORDER BY s.id DESC")) (Only tid)
       :: IO [Row])
    liftIO (mapM toSub rows)

  listSubstitutionsForTeam :: TeamName -> SQLiteM [Substitution]
  listSubstitutionsForTeam (TeamName tname) = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn (fromString' (selectBase ++ "WHERE t.name = ? COLLATE NOCASE ORDER BY s.id DESC")) (Only tname)
       :: IO [Row])
    liftIO (mapM toSub rows)

  getSubstitution :: Int -> SQLiteM (Maybe Substitution)
  getSubstitution sid = do
    conn <- asks envConnection
    rows <- liftIO $
      (query conn (fromString' (selectBase ++ "WHERE s.id = ?")) (Only sid)
       :: IO [Row])
    case rows of
      []      -> pure Nothing
      (r : _) -> Just <$> liftIO (toSub r)

  setSubstitutionStatus :: Int -> UserId -> SubstitutionStatus -> SQLiteM ()
  setSubstitutionStatus sid (UserId by) st = do
    conn <- asks envConnection
    liftIO $ execute conn
      "UPDATE team_substitutions SET status = ?, decided_by = ? WHERE id = ?"
      (statusToText st, by, sid)

fromString' :: String -> Query
fromString' = fromString
