{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs #-}
module Shell.Persistence.SQLite.BracketRepository () where

import Control.Exception (throwIO)
import Control.Monad (forM_, foldM, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text, unpack)
import Database.SQLite.Simple (Connection, changes, execute, query, lastInsertRowId, Only(..))

import Domain.Bracket (Bracket(..),  BracketNode(..),BracketSide(..), MatchSlot(..))
import Domain.Participant (Participant(..), ParticipantId(..), Player(..), PlayerName(..), Team(..), TeamName(..))
import Domain.Tournament (TournamentId(..))
import Shell.Persistence.Port (BracketRepository(..), ParticipantRepository(..))
import Shell.Persistence.SQLite.Connection (SQLiteEnv(envConnection), SQLiteM, withTxM)
import Shell.Persistence.SQLite.Error (PersistenceError(..))
import Shell.Persistence.SQLite.ParticipantRepository ()
import Shell.Persistence.SQLite.Common (lookupParticipantId)
import Domain.Ids(BracketNodeId(..), BracketId(..))


instance BracketRepository SQLiteM where

    -- Mints a fresh BracketId, mirroring createTournament's pattern.
    -- saveBracket (below) is purely the post-creation update path -- it
    -- never inserts a brackets row itself.
    createBracket :: TournamentId -> SQLiteM BracketId
    createBracket (TournamentId tid) = do
        conn <- asks envConnection
        liftIO $ execute conn
            "INSERT INTO brackets (tournament_id) VALUES (?)"
            (Only tid)
        rid <- liftIO $ lastInsertRowId conn
        pure (BracketId (fromIntegral rid))

    saveBracket :: Bracket -> [BracketNode] -> SQLiteM (Map BracketNodeId BracketNodeId)
    saveBracket bracket nodes =  do
        conn <- asks envConnection
        let BracketId bid = bracketId bracket
        let TournamentId tid = bracketTournament bracket

        liftIO $ execute conn
            "UPDATE brackets SET tournament_id = ? WHERE id = ?"
            (tid, bid)

        liftIO $ execute conn
            "DELETE FROM bracket_nodes WHERE bracket_id = ?"
            (Only bid)

        resolved <- mapM resolveNodeForSave nodes

        -- Pass 1: insert nodes without node-id references; SQLite mints
        -- the row id. Build domain BracketNodeId -> SQLite rowid map.
        -- Rejects duplicate domain ids with StorageFailure.
        idMap <- liftIO $ foldM (\acc (nid, rnd, stage, aType, aPid, _, bType, bPid, _) -> do
            when (Map.member nid acc) $
                throwIO (StorageFailure ("Duplicate BracketNodeId in save: " ++ show nid))
            liftIO $ do
                putStrLn ("atype = " ++ show aType)
                putStrLn ("btype = " ++ show bType)
                putStrLn ("apid = " ++ show aPid)
                putStrLn ("bpid = " ++ show bPid)
            execute conn
                "INSERT INTO bracket_nodes \
                \  (bracket_id, round, stage, \
                \   slot_a_type, slot_a_participant_id, slot_a_node_id, \
                \   slot_b_type, slot_b_participant_id, slot_b_node_id) \
                \VALUES (?, ?, ?, ?, ?, NULL, ?, ?, NULL)"
                (bid, rnd, stage, aType, aPid, bType, bPid)
            sqliteId <- lastInsertRowId conn
            pure (Map.insert nid sqliteId acc)
            ) Map.empty resolved

        -- Pass 2: wire up node-to-node references via the id map.
        -- A dangling reference (points at a BracketNodeId never inserted
        -- this save) is a graph-generation bug, not a storage detail --
        -- fail loudly rather than silently writing NULL.
        liftIO $ forM_ resolved $ \(nid, _, _, _, _, aRef, _, _, bRef) -> do
            sqliteId <- case Map.lookup nid idMap of
                Just sid -> pure sid
                Nothing  -> throwIO (StorageFailure ("Domain node id " ++ show nid ++ " missing from id map"))
            aNid <- lookupNodeRef "AwaitingWinnerOf" idMap aRef
            bNid <- lookupNodeRef "AwaitingLoserOf" idMap bRef
            case (aNid, bNid) of
                (Nothing, Nothing) -> pure ()
                _ -> execute conn
                    "UPDATE bracket_nodes SET slot_a_node_id = ?, slot_b_node_id = ? WHERE id = ?"
                    (aNid, bNid, sqliteId)

                -- (unchanged: initial tournament_id UPDATE, DELETE, Pass 1, Pass 2)

        let translateRef label mRef = case mRef of
              Nothing -> pure Nothing
              Just (BracketNodeId domainId) -> case Map.lookup (fromIntegral domainId) idMap of
                  Just sid -> pure (Just sid)
                  Nothing  -> throwIO (StorageFailure (label ++ " references unknown BracketNodeId " ++ show domainId))
        gf1Sid   <- liftIO $ translateRef "gf1_node_id" (bracketGF1NodeId bracket)
        resetSid <- liftIO $ translateRef "reset_node_id" (bracketResetNodeId bracket)
        liftIO $ execute conn
            "UPDATE brackets SET gf1_node_id = ?, reset_node_id = ? WHERE id = ?"
            (gf1Sid, resetSid, bid)

        pure (Map.mapKeys (BracketNodeId . fromIntegral) (Map.map (BracketNodeId . fromIntegral) idMap))

    getBracket :: BracketId -> SQLiteM (Bracket, [BracketNode])
    getBracket bid@(BracketId bracketIdNum) = do
        conn <- asks envConnection
        header <- liftIO ( query conn
            "SELECT tournament_id, gf1_node_id, reset_node_id FROM brackets WHERE id = ?"
            (Only bracketIdNum) :: IO [(Int64, Maybe Int64, Maybe Int64)])
        case header of
            [(tid, gf1Sid, resetSid)] -> do
                rows <- liftIO (query conn
                    "SELECT id, round, stage, \
                    \  slot_a_type, slot_a_participant_id, slot_a_node_id, \
                    \  slot_b_type, slot_b_participant_id, slot_b_node_id \
                    \FROM bracket_nodes WHERE bracket_id = ? \
                    \ORDER BY round, CASE stage WHEN 'Winners' THEN 0 ELSE 1 END, id"
                    (Only bracketIdNum) :: IO [(Int64, Int, Text, Text, Maybe Int64, Maybe Int64, Text, Maybe Int64, Maybe Int64)])
                nodes <- mapM hydrateNode rows
                pure ( Bracket
                         { bracketId = bid
                         , bracketTournament = TournamentId (fromIntegral tid)
                         , bracketGF1NodeId   = BracketNodeId . fromIntegral <$> gf1Sid
                         , bracketResetNodeId = BracketNodeId . fromIntegral <$> resetSid
                         }
                     , nodes )
            [] -> liftIO $ throwIO (NotFound ("Bracket not found in storage: " ++ show bracketIdNum))
            _  -> liftIO $ throwIO (StorageFailure "brackets.id is PRIMARY KEY but multiple rows in storage")

    deleteBracket :: BracketId -> SQLiteM ()
    deleteBracket (BracketId bid) = withTxM $ do
        conn <- asks envConnection
        liftIO $ execute conn "DELETE FROM bracket_nodes WHERE bracket_id = ?" (Only bid)
        liftIO $ execute conn "DELETE FROM brackets WHERE id = ?" (Only bid)
        n <- liftIO $ changes conn
        when (n == 0) $
            liftIO $ throwIO (NotFound ("Bracket not found in storage: " ++ show bid))

    updateNodeSlots :: BracketNode -> SQLiteM ()
    updateNodeSlots node = do
      conn <- asks envConnection
      let BracketNodeId nid = nodeId node
      (aType, aPid, aRef) <- slotColumns (nodeSlotA node)
      (bType, bPid, bRef) <- slotColumns (nodeSlotB node)
      liftIO $ execute conn
           "UPDATE bracket_nodes SET \
           \  slot_a_type = ?, slot_a_participant_id = ?, slot_a_node_id = ?, \
           \  slot_b_type = ?, slot_b_participant_id = ?, slot_b_node_id = ? \
           \WHERE id = ?"
           (aType, aPid, aRef, bType, bPid, bRef, fromIntegral nid :: Int64)
      n <- liftIO $ changes conn
      when (n == 0) $
        liftIO $ throwIO (NotFound ("Bracket node not found in storage: " ++ show nid))


-- Private helpers -----------------------------------------------------------

resolveNodeForSave :: BracketNode -> SQLiteM (Int64, Int, Text, Text, Maybe Int64, Maybe Int64, Text, Maybe Int64, Maybe Int64)
resolveNodeForSave node = do
    let BracketNodeId nid = nodeId node
    (aType, aPid, aRef) <- slotColumns (nodeSlotA node)
    (bType, bPid, bRef) <- slotColumns (nodeSlotB node)
    pure (fromIntegral nid, nodeRound node, bracketSideToString (nodeStage node),
          aType, aPid, aRef, bType, bPid, bRef)

slotColumns :: MatchSlot -> SQLiteM (Text, Maybe Int64, Maybe Int64)
slotColumns (Filled participant) = do
    pid <- lookupParticipantId participant
    pure ("Filled", Just pid, Nothing)
slotColumns (AwaitingWinnerOf (BracketNodeId nid)) = pure ("AwaitingWinner", Nothing, Just (fromIntegral nid))
slotColumns (AwaitingLoserOf (BracketNodeId nid))  = pure ("AwaitingLoser", Nothing, Just (fromIntegral nid))
slotColumns ByeSlot                                = pure ("Bye", Nothing, Nothing)

-- Given a domain->SQLite id map and an optional referenced BracketNodeId,
-- resolve it to the referenced row's SQLite id. Nothing (no reference) is
-- valid and passes through; Just ref that isn't in idMap is a genuine
-- graph-generation bug and fails loudly rather than writing NULL silently.
lookupNodeRef :: Text -> Map Int64 Int64 -> Maybe Int64 -> IO (Maybe Int64)
lookupNodeRef _     _     Nothing    = pure Nothing
lookupNodeRef label idMap (Just ref) = case Map.lookup ref idMap of
    Just sid -> pure (Just sid)
    Nothing  -> throwIO (StorageFailure (unpack label ++ " references unknown BracketNodeId " ++ show ref))


hydrateNode :: (Int64, Int, Text, Text, Maybe Int64, Maybe Int64, Text, Maybe Int64, Maybe Int64) -> SQLiteM BracketNode
hydrateNode (rid, rnd, stageTxt, aType, aPid, aNid, bType, bPid, bNid) = do
    slotA <- hydrateSlot aType aPid aNid
    slotB <- hydrateSlot bType bPid bNid
    stage <- textToSide stageTxt
    pure BracketNode { nodeId = BracketNodeId (fromIntegral rid), nodeSlotA = slotA, nodeSlotB = slotB, nodeRound = rnd, nodeStage = stage }

hydrateSlot :: Text -> Maybe Int64 -> Maybe Int64 -> SQLiteM MatchSlot
hydrateSlot slotType participantIdCol nodeIdCol = case slotType of
    "Filled" -> case participantIdCol of
        Just pid -> Filled <$> getParticipant (ParticipantId (fromIntegral pid))
        Nothing  -> liftIO $ throwIO $ StorageFailure "Filled slot in storage missing participant_id"
    "AwaitingWinner" -> case nodeIdCol of
        Just nid -> pure (AwaitingWinnerOf (BracketNodeId (fromIntegral nid)))
        Nothing  -> liftIO $ throwIO $ StorageFailure "AwaitingWinner slot in storage missing node_id"
    "AwaitingLoser" -> case nodeIdCol of
        Just nid -> pure (AwaitingLoserOf (BracketNodeId (fromIntegral nid)))
        Nothing  -> liftIO $ throwIO $ StorageFailure "AwaitingLoser slot in storage missing node_id"
    "Bye" -> pure ByeSlot
    other -> liftIO $ throwIO $ StorageFailure ("Unknown slot_type in storage: " ++ show other)

textToSide :: Text -> SQLiteM BracketSide
textToSide "Winners" = pure Winners
textToSide "Losers"  = pure Losers
textToSide other     = liftIO $ throwIO $ StorageFailure ("Unknown bracket stage in storage: " ++ show other)

bracketSideToString :: BracketSide -> Text
bracketSideToString Winners = "Winners"
bracketSideToString Losers  = "Losers"