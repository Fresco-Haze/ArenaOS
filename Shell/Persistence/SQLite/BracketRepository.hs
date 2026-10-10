{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs #-}
module Shell.Persistence.SQLite.BracketRepository () where

import Control.Exception (throwIO)
import Control.Monad (forM_, foldM, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.Int (Int64)
import Data.List (sort)
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
import Domain.BracketLinks (BracketLinks, NodeDestination(..), NodeLinks(..), SlotPosition(..))


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

        liftIO $ execute conn "DELETE FROM bracket_links WHERE bracket_id = ?" (Only bid)
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
        thirdPlaceSid <- liftIO $ translateRef "third_place_node_id" (bracketThirdPlaceNodeId bracket)
        liftIO $ execute conn
           "UPDATE brackets SET gf1_node_id = ?, reset_node_id = ?, third_place_node_id = ? WHERE id = ?"
            (gf1Sid, resetSid, thirdPlaceSid, bid)

        pure (Map.mapKeys (BracketNodeId . fromIntegral) (Map.map (BracketNodeId . fromIntegral) idMap))
        
    getBracket :: BracketId -> SQLiteM (Bracket, [BracketNode])
    getBracket bid@(BracketId bracketIdNum) = do
        conn <- asks envConnection
        header <- liftIO ( query conn
            "SELECT tournament_id, gf1_node_id, reset_node_id, third_place_node_id FROM brackets WHERE id = ?"
            (Only bracketIdNum) :: IO [(Int64, Maybe Int64, Maybe Int64, Maybe Int64)])
        case header of
            [(tid, gf1Sid, resetSid, thirdPlaceSid)] -> do
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
                         , bracketThirdPlaceNodeId = BracketNodeId . fromIntegral <$> thirdPlaceSid
                         }
                     , nodes )
            [] -> liftIO $ throwIO (NotFound ("Bracket not found in storage: " ++ show bracketIdNum))
            _  -> liftIO $ throwIO (StorageFailure "brackets.id is PRIMARY KEY but multiple rows in storage")

    deleteBracket :: BracketId -> SQLiteM ()
    deleteBracket (BracketId bid) = withTxM $ do
        conn <- asks envConnection
        liftIO $ execute conn "DELETE FROM bracket_links WHERE bracket_id = ?" (Only bid)
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


    -- Persist the link set of a just-saved bracket. Links are keyed by DOMAIN
    -- node ids (as generated); idMap is the map saveBracket returned (domain id ->
    -- stored id). Everything is validated before the first insert, so a rejected
    -- save writes nothing. No transaction of its own: the caller owns it.
    saveBracketLinks :: BracketId -> Map BracketNodeId BracketNodeId -> BracketLinks -> SQLiteM ()
    saveBracketLinks (BracketId bid) idMap links = do
        conn <- asks envConnection
        -- 1. coverage, in domain ids: every mapped node is named exactly once
        let linkIds = sort (map fst links)
        when (or (zipWith (==) linkIds (drop 1 linkIds))) $
            failStorage "bracket links list a node more than once"
        when (linkIds /= Map.keys idMap) $
            failStorage "bracket links do not cover exactly the saved nodes"
        -- 2. ownership, in stored ids: the map's values must be exactly the rows
        --    stored under this bracket (no extras, no strays, no shared ids)
        owned <- liftIO (query conn
            "SELECT id FROM bracket_nodes WHERE bracket_id = ? ORDER BY id"
            (Only bid) :: IO [Only Int64])
        when (sort (map storedId (Map.elems idMap)) /= [ i | Only i <- owned ]) $
            failStorage "the id map is not exactly the set of nodes stored for this bracket"
        -- 3. translation: every source and destination goes through the map
        rows <- case mapM (linkRow idMap) links of
            Left why -> failStorage why
            Right rs -> pure rs
        liftIO $ forM_ rows $ \(nodeSid, wNode, wSlot, lNode, lSlot) ->
            execute conn
                "INSERT INTO bracket_links \
                \  (node_id, bracket_id, winner_node_id, winner_slot, loser_node_id, loser_slot) \
                \VALUES (?, ?, ?, ?, ?, ?)"
                (nodeSid, bid, wNode, wSlot, lNode, lSlot)

    -- Nothing when no link rows exist. Otherwise the rows must cover exactly this
    -- bracket's nodes, every destination must be one of them, and every slot must
    -- decode; anything else is a StorageFailure, never a partial answer.
    getBracketLinks :: BracketId -> SQLiteM (Maybe BracketLinks)
    getBracketLinks (BracketId bid) = do
        conn <- asks envConnection
        rows <- liftIO (query conn
            "SELECT node_id, winner_node_id, winner_slot, loser_node_id, loser_slot \
            \FROM bracket_links WHERE bracket_id = ? ORDER BY node_id"
            (Only bid) :: IO [LinkRow])
        case rows of
            [] -> pure Nothing
            _  -> do
                nodeRows <- liftIO (query conn
                    "SELECT id FROM bracket_nodes WHERE bracket_id = ? ORDER BY id"
                    (Only bid) :: IO [Only Int64])
                let nodeIds = [ i | Only i <- nodeRows ]
                when (nodeIds /= [ i | (i, _, _, _, _) <- rows ]) $
                    failStorage "bracket links do not cover exactly the bracket's nodes"
                links <- liftIO (mapM (hydrateLinks nodeIds) rows)
                pure (Just links)

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

-- Bracket links helpers -----------------------------------------------------

failStorage :: String -> SQLiteM a
failStorage msg = liftIO (throwIO (StorageFailure msg))

storedId :: BracketNodeId -> Int64
storedId (BracketNodeId n) = fromIntegral n

type LinkRow = (Int64, Maybe Int64, Maybe Text, Maybe Int64, Maybe Text)

encodeSlotPosition :: SlotPosition -> Text
encodeSlotPosition SlotA = "A"
encodeSlotPosition SlotB = "B"

decodeSlotPosition :: Text -> IO SlotPosition
decodeSlotPosition "A"   = pure SlotA
decodeSlotPosition "B"   = pure SlotB
decodeSlotPosition other = throwIO (StorageFailure ("Unknown link slot in storage: " ++ show other))

linkRow :: Map BracketNodeId BracketNodeId -> (BracketNodeId, NodeLinks) -> Either String LinkRow
linkRow idMap (src, NodeLinks w l) = do
    s  <- toStored "source" src
    wd <- traverse toDest w
    ld <- traverse toDest l
    pure (s, fst <$> wd, snd <$> wd, fst <$> ld, snd <$> ld)
  where
    toStored :: String -> BracketNodeId -> Either String Int64
    toStored what nid = case Map.lookup nid idMap of
        Just sid -> Right (storedId sid)
        Nothing  -> Left ("bracket link " ++ what ++ " " ++ show nid ++ " is not a saved node")
    toDest :: NodeDestination -> Either String (Int64, Text)
    toDest (NodeDestination n pos) = do
        sid <- toStored "destination" n
        pure (sid, encodeSlotPosition pos)

hydrateLinks :: [Int64] -> LinkRow -> IO (BracketNodeId, NodeLinks)
hydrateLinks nodeIds (nid, wNode, wSlot, lNode, lSlot) = do
    w <- hydrateDest "winner" wNode wSlot
    l <- hydrateDest "loser" lNode lSlot
    pure (BracketNodeId (fromIntegral nid), NodeLinks w l)
  where
    hydrateDest :: String -> Maybe Int64 -> Maybe Text -> IO (Maybe NodeDestination)
    hydrateDest _ Nothing Nothing = pure Nothing
    hydrateDest what (Just d) (Just s)
        | d `elem` nodeIds = do
            pos <- decodeSlotPosition s
            pure (Just (NodeDestination (BracketNodeId (fromIntegral d)) pos))
        | otherwise = throwIO (StorageFailure ("link " ++ what ++ " destination " ++ show d ++ " is not a node of this bracket"))
    hydrateDest what _ _ = throwIO (StorageFailure ("link " ++ what ++ " destination is half-set in storage"))
