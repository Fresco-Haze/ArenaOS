{-# LANGUAGE OverloadedStrings #-}
module Shell.Persistence.SQLite.Common
  ( lookupParticipantId
  ) where

import Control.Exception (throwIO)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.Int (Int64)
import Database.SQLite.Simple (Connection, query, Only(..))

import Domain.Participant (Participant(..), Player(..), PlayerName(..), Team(..), TeamName(..))
import Shell.Persistence.SQLite.Connection (SQLiteEnv(envConnection), SQLiteM)
import Shell.Persistence.SQLite.Error (PersistenceError(..))

-- Deliberately a read-only lookup, not resolveParticipant: per DP-002's
-- addendum, identity-minting is the caller/domain-service's job before
-- persistence begins, not something a Filled-slot save should trigger.
-- Callers assume the Participant already has a resolved identity.
lookupParticipantId :: Participant -> SQLiteM Int64
lookupParticipantId participant = do
    conn <- asks envConnection
    case participant of
        Individual player -> do
            let PlayerName pname = playerName player
            pRows <- liftIO (query conn "SELECT id FROM players WHERE name = ?" (Only pname) :: IO [Only Int64])
            case pRows of
                [Only pid] -> findIndividual conn pid
                []          -> liftIO $ throwIO $ NotFound ("Player not found in storage: " ++ pname)
                _           -> liftIO $ throwIO $ StorageFailure "players.name is UNIQUE but multiple rows in storage"
        Squad team -> do
            let TeamName tname = teamName team
            tRows <- liftIO (query conn "SELECT id FROM teams WHERE name = ?" (Only tname) :: IO [Only Int64])
            case tRows of
                [Only tid] -> findSquad conn tid
                []          -> liftIO $ throwIO $ NotFound ("Team not found in storage: " ++ tname)
                _           -> liftIO $ throwIO $ StorageFailure "teams.name is UNIQUE but multiple rows in storage"
  where
    findIndividual :: Connection -> Int64 -> SQLiteM Int64
    findIndividual conn pid = do
        rows <- liftIO (query conn
            "SELECT id FROM participants WHERE kind = 'Individual' AND player_id = ?"
            (Only pid) :: IO [Only Int64])
        reportLookup rows "player"

    findSquad :: Connection -> Int64 -> SQLiteM Int64
    findSquad conn tid = do
        rows <- liftIO (query conn
            "SELECT id FROM participants WHERE kind = 'Squad' AND team_id = ?"
            (Only tid) :: IO [Only Int64])
        reportLookup rows "team"

    reportLookup :: [Only Int64] -> String -> SQLiteM Int64
    reportLookup rows label = case rows of
        [Only pid] -> pure pid
        []          -> liftIO $ throwIO $ StorageFailure ("Filled slot: participant not found in storage for " ++ label)
        _           -> liftIO $ throwIO $ StorageFailure ("Filled slot: multiple participant rows in storage for same " ++ label)