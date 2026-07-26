-- Shell.Persistence.SQLite.Error
-- Stage 1: Infrastructure.
--
-- Verified against GHC.
-- Any assumptions about sqlite-simple behavior should continue to be
-- validated against the library documentation and integration tests.

{-# LANGUAGE ScopedTypeVariables #-}

module Shell.Persistence.SQLite.Error
  ( PersistenceError(..)
  , fromSQLiteException
  , runSQLite
  ) where

import Control.Exception (Exception, catch)
import Database.SQLite.Simple (SQLError(..))
import qualified Database.SQLite.Simple as SQLite

-- Canonical persistence error type.
-- The constructors must remain consistent with the repository port
-- (Architecture.md Section 13.4). Their propagation semantics are
-- defined by ADR-007 (SQLite Adapter Execution and Failure Model).
data PersistenceError
  = NotFound String
  | ConstraintViolation String
  | StorageFailure String
  deriving (Show, Eq)

instance Exception PersistenceError

-- | Map a caught SQLite exception to the port-level PersistenceError.
fromSQLiteException :: SQLError -> PersistenceError
fromSQLiteException err = case SQLite.sqlError err of
    SQLite.ErrorConstraint -> ConstraintViolation (show err)
    _                       -> StorageFailure (show err)

-- | Sole translation boundary for the SQLite adapter (see ADR-007).
-- fromSQLiteException never constructs NotFound -- missing rows are
-- not reported by SQLite as errors; repository methods detect empty
-- query results and raise NotFound directly. runSQLite catches both
-- repository-raised PersistenceErrors and SQLite-raised SQLErrors,
-- establishing a single persistence failure boundary. Exceptions
-- unrelated to persistence are intentionally allowed to propagate.
runSQLite :: IO a -> IO (Either PersistenceError a)
runSQLite action =
    (Right <$> action)
      `catch` (\(e :: PersistenceError) -> pure (Left e))
      `catch` (\(e :: SQLError) -> pure (Left (fromSQLiteException e)))