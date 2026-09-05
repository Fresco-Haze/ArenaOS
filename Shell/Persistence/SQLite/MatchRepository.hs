{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE InstanceSigs #-}
module Shell.Persistence.SQLite.MatchRepository () where

import Control.Exception (throwIO)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.Int (Int64)
import Data.Text (Text, unpack)
import Database.SQLite.Simple (execute, query, lastInsertRowId, Only(..), changes)

import Domain.Bracket (BracketId(..), BracketNodeId(..))
import Domain.Match(Match(..), MatchId(..), MatchStatus(..), MatchOutcome(..))
import Domain.Participant (ParticipantId(..))
import Domain.Tournament (TournamentId(..))
import Shell.Persistence.Port (MatchRepository(..), NewMatch(..), ParticipantRepository(..))
import Shell.Persistence.SQLite.Common (lookupParticipantId)
import Shell.Persistence.SQLite.Connection (SQLiteEnv(envConnection), SQLiteM)
import Shell.Persistence.SQLite.Error (PersistenceError(..))
import Shell.Persistence.SQLite.ParticipantRepository ()


instance MatchRepository SQLiteM where
    createMatch :: NewMatch -> SQLiteM MatchId
    createMatch nm = do
        conn <- asks envConnection
        liftIO $ execute conn
            "INSERT INTO matches \
            \(tournament_id, bracket_id, bracket_node_id, \
            \ competitor_a_participant_id, competitor_b_participant_id, status) \
            \VALUES (?, ?, ?, ?, ?, 'Scheduled')"
            ( unTournamentId  (newMatchTournament nm)
            , unBracketId     (newMatchBracket nm)
            , unBracketNodeId (newMatchBracketNode nm)  -- DI-12
            , unParticipantId (newMatchCompetitorA nm)
            , unParticipantId (newMatchCompetitorB nm)
            )
        rid <- liftIO $ lastInsertRowId conn
        pure (MatchId (fromIntegral rid))

    saveMatch :: Match -> SQLiteM ()
    saveMatch m = do
        conn <- asks envConnection
        (outcomeType, outcomeParticipant) <- matchOutcomeToColumns (matchOutcome m)
        aPid <- lookupParticipantId (matchCompetitorA m)
        bPid <- lookupParticipantId (matchCompetitorB m)
        liftIO $ execute conn
            "INSERT INTO matches \
            \(id, tournament_id, bracket_id, bracket_node_id, \
            \ competitor_a_participant_id, competitor_b_participant_id, \
            \ status, outcome_type, outcome_participant_id) \
            \VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) \
            \ON CONFLICT(id) DO UPDATE SET \
            \  competitor_a_participant_id = excluded.competitor_a_participant_id,\
            \  competitor_b_participant_id = excluded.competitor_b_participant_id,\
            \  status = excluded.status, \
            \  outcome_type = excluded.outcome_type, \
            \  outcome_participant_id = excluded.outcome_participant_id"
            ( unMatchId       (matchId m)
            , unTournamentId  (matchTournament m)
            , unBracketId     (matchBracket m)
            , unBracketNodeId (matchBracketNode m)  -- DI-12
            , aPid
            , bPid
            , statusToText (matchStatus m)
            , outcomeType
            , outcomeParticipant
            )

    getMatch :: MatchId -> SQLiteM Match
    getMatch mid = do
        conn <- asks envConnection
        rows <- liftIO
            (query conn
                "SELECT tournament_id, bracket_id, bracket_node_id, \
                \competitor_a_participant_id, competitor_b_participant_id, status, \
                \outcome_type, outcome_participant_id \
                \FROM matches WHERE id = ?"
                (Only (unMatchId mid))
                :: IO [MatchRow])
        case rows of
            []        -> liftIO (throwIO (NotFound "Match" ))
            (row : _) -> hydrateMatch mid row

    listMatchesForBracket :: BracketId -> SQLiteM [Match]
    listMatchesForBracket (BracketId bid) = do
        conn <- asks envConnection
        rows <- liftIO
            (query conn
                "SELECT id, tournament_id, bracket_id, bracket_node_id, \
                \competitor_a_participant_id, competitor_b_participant_id, status, \
                \outcome_type, outcome_participant_id \
                \FROM matches WHERE bracket_id = ? ORDER BY id"
                (Only bid)
                :: IO [(Int64, Int64, Int64, Int64, Int64, Int64, Text, Maybe Text, Maybe Int64)])
        mapM hydrateListedMatch rows

    deleteMatch :: MatchId -> SQLiteM ()
    deleteMatch (MatchId mid) = do
        conn <- asks envConnection
        liftIO $ execute conn "DELETE FROM matches WHERE id = ?" (Only mid)
        n <- liftIO $ changes conn
        when (n == 0) $
            liftIO $ throwIO $ NotFound "Match" 


-- Private helpers -----------------------------------------------------------

statusToText :: MatchStatus -> Text
statusToText Scheduled  = "Scheduled"
statusToText InProgress = "InProgress"
statusToText Completed  = "Completed"
statusToText Cancelled  = "Cancelled"

textToStatus :: Text -> SQLiteM MatchStatus
textToStatus "Scheduled"  = pure Scheduled
textToStatus "InProgress" = pure InProgress
textToStatus "Completed"  = pure Completed
textToStatus "Cancelled"  = pure Cancelled
textToStatus t = liftIO $ throwIO $ StorageFailure ("Unknown match status in storage: " ++ unpack t)

matchOutcomeToColumns :: Maybe MatchOutcome -> SQLiteM (Maybe Text, Maybe Int64)
matchOutcomeToColumns Nothing = pure (Nothing, Nothing)
matchOutcomeToColumns (Just outcome) = case outcome of
    Winner p           -> withParticipant "Winner" p
    Forfeit p          -> withParticipant "Forfeit" p
    Disqualification p -> withParticipant "Disqualification" p
    Draw                -> pure (Just "Draw", Nothing)
    NoContest           -> pure (Just "NoContest", Nothing)
  where
    withParticipant label p = do
        pid <- lookupParticipantId p
        pure (Just label, Just pid)

columnsToMatchOutcome :: Maybe Text -> Maybe Int64 -> SQLiteM (Maybe MatchOutcome)
columnsToMatchOutcome Nothing Nothing = pure Nothing
columnsToMatchOutcome (Just "Draw") Nothing = pure (Just Draw)
columnsToMatchOutcome (Just "NoContest") Nothing = pure (Just NoContest)
columnsToMatchOutcome (Just "Winner") (Just pid) =
    Just . Winner <$> getParticipant (ParticipantId (fromIntegral pid))
columnsToMatchOutcome (Just "Forfeit") (Just pid) =
    Just . Forfeit <$> getParticipant (ParticipantId (fromIntegral pid))
columnsToMatchOutcome (Just "Disqualification") (Just pid) =
    Just . Disqualification <$> getParticipant (ParticipantId (fromIntegral pid))
columnsToMatchOutcome (Just t) Nothing =
    liftIO $ throwIO $ StorageFailure ("Match outcome '" ++ unpack t ++ "' missing required participant id in storage")
columnsToMatchOutcome (Just "Draw") (Just _) =
    liftIO $ throwIO $ StorageFailure "Match outcome 'Draw' has an unexpected participant id in storage"
columnsToMatchOutcome (Just "NoContest") (Just _) =
    liftIO $ throwIO $ StorageFailure "Match outcome 'NoContest' has an unexpected participant id in storage"
columnsToMatchOutcome (Just t) (Just _) =
    liftIO $ throwIO $ StorageFailure ("Unknown match outcome type in storage: " ++ unpack t)
columnsToMatchOutcome Nothing (Just _) =
    liftIO $ throwIO $ StorageFailure "Match has a participant id but no outcome type in storage"

validateStatusOutcome :: MatchId -> MatchStatus -> Maybe MatchOutcome -> SQLiteM ()
validateStatusOutcome (MatchId mid) status outcome =
    case (status, outcome) of
        (Completed, Nothing) ->
            liftIO $ throwIO $ StorageFailure ("Completed match missing outcome in storage: " ++ show mid)
        (Scheduled, Just _) ->
            liftIO $ throwIO $ StorageFailure ("Scheduled match has an outcome in storage: " ++ show mid)
        (InProgress, Just _) ->
            liftIO $ throwIO $ StorageFailure ("InProgress match has an outcome in storage: " ++ show mid)
        _ -> pure ()

-- (tournament_id, bracket_id, bracket_node_id, competitor_a_id, competitor_b_id,
--  status, outcome_type, outcome_participant_id)
type MatchRow = (Int64, Int64, Int64, Int64, Int64, Text, Maybe Text, Maybe Int64)

hydrateMatch :: MatchId -> MatchRow -> SQLiteM Match
hydrateMatch mid (tid, bid, bnid, aPid, bPid, statusText, outcomeType, outcomePid) = do
    status  <- textToStatus statusText
    outcome <- columnsToMatchOutcome outcomeType outcomePid
    validateStatusOutcome mid status outcome
    compA <- getParticipant (ParticipantId (fromIntegral aPid))
    compB <- getParticipant (ParticipantId (fromIntegral bPid))
    let nodeId' = BracketNodeId (fromIntegral bnid)
    pure Match
        { matchId          = mid
        , matchTournament   = TournamentId (fromIntegral tid)
        , matchBracket      = BracketId (fromIntegral bid)
        , matchBracketNode  = nodeId'  -- DI-12
        , matchCompetitorA       = compA
        , matchCompetitorB       = compB
        , matchStatus       = status
        , matchOutcome      = outcome
        }

hydrateListedMatch
    :: (Int64, Int64, Int64, Int64, Int64, Int64, Text, Maybe Text, Maybe Int64)
    -> SQLiteM Match
hydrateListedMatch (mid, tid, bid, bnid, aPid, bPid, statusText, outcomeType, outcomePid) =
    hydrateMatch (MatchId mid) (tid, bid, bnid, aPid, bPid, statusText, outcomeType, outcomePid)