-- Shell.Persistence.SQLite.Connection
-- Stage 1: Infrastructure.
--
-- Verified against GHC.
-- Any assumptions about sqlite-simple behavior should continue to be
-- validated against the library documentation and integration tests.

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Shell.Persistence.SQLite.Connection
  ( withConnection
  , withTx
  ,withTxM
  , SQLiteEnv(envConnection)
  , SQLiteM
  , runSQLiteM
  , Transactional(..)
  ) where

import Control.Exception (bracket)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (ReaderT, runReaderT, MonadReader, ask)
import Database.SQLite.Simple (Connection, open, close, execute_)
import qualified Database.SQLite.Simple as SQLite

import Shell.Persistence.SQLite.Error (PersistenceError, runSQLite)
import Shell.Persistence.Port (Transactional(..))

-- | Open a connection, run an action, always close -- even on
-- exception. Also enables foreign key enforcement, which SQLite
-- leaves OFF by default per-connection.
withConnection :: FilePath -> (Connection -> IO a) -> IO a
withConnection dbPath action =
    bracket (open dbPath) close $ \conn -> do
        enableForeignKeys conn
        action conn
  where
    enableForeignKeys conn = execute_ conn "PRAGMA foreign_keys = ON"

-- | Run an action inside a SQLite transaction. Rolls back
-- automatically if the action throws.
withTx :: Connection -> IO a -> IO a
withTx = SQLite.withTransaction


-- | Environment available to every SQLiteM computation.
newtype SQLiteEnv = SQLiteEnv
  { envConnection :: Connection
  }

-- | Adapter execution monad. SQLite repository instances run inside
-- this. See ADR-007: SQLite Adapter Execution and Failure Model.
newtype SQLiteM a = SQLiteM
  { unSQLiteM :: ReaderT SQLiteEnv IO a
  } deriving (Functor, Applicative, Monad, MonadIO, MonadReader SQLiteEnv)

-- | Sole entry point for running a SQLiteM computation: acquires a
-- connection, builds the environment, runs the computation, and
-- translates any thrown PersistenceError/SQLError into Left. See
-- ADR-007.
runSQLiteM :: FilePath -> SQLiteM a -> IO (Either PersistenceError a)
runSQLiteM dbPath (SQLiteM action) =
    withConnection dbPath $ \conn ->
        runSQLite $ runReaderT action (SQLiteEnv conn)

withTxM :: SQLiteM a -> SQLiteM a
withTxM (SQLiteM action) = SQLiteM $ do
    env <- ask
    liftIO $
        withTx (envConnection env) $
            runReaderT action env

instance Transactional SQLiteM where
  withTxN = withTxM