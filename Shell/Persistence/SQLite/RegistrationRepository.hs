{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- Shell.Persistence.SQLite.RegistrationRepository
module Shell.Persistence.SQLite.RegistrationRepository () where

import Control.Exception (throwIO)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)

import Database.SQLite.Simple (Only(..), changes, execute, query, lastInsertRowId)

import Domain.Registration
    ( Registration(..)
    , RegistrationId(..)
    , RegistrationStatus(..)
    )
import Domain.Tournament (TournamentId(..))
import Domain.Participant (Participant, ParticipantId(..))

import Shell.Persistence.Port
    ( RegistrationRepository(..)
    , NewRegistration(..)
    , ParticipantRepository(getParticipant)
    )
import Shell.Persistence.SQLite.Connection (SQLiteEnv(..), SQLiteM)
import Shell.Persistence.SQLite.Error (PersistenceError(..))
import Shell.Persistence.SQLite.ParticipantRepository ()

-- RegistrationStatus <-> Text. Single-constructor today (INV-2), but
-- written as a real function rather than an inline literal so a
-- future second constructor only changes this helper, not every
-- call site.
registrationStatusToText :: RegistrationStatus -> String
registrationStatusToText Confirmed = "Confirmed"

textToRegistrationStatus :: String -> IO RegistrationStatus
textToRegistrationStatus "Confirmed" = pure Confirmed
textToRegistrationStatus other       =
    throwIO (StorageFailure ("Unknown registration status in storage: " ++ other))

instance RegistrationRepository SQLiteM where

    createRegistration :: NewRegistration -> SQLiteM RegistrationId
    createRegistration nr = do
        conn <- asks envConnection
        let TournamentId tidInt  = newRegistrationTournament nr
            ParticipantId pidInt = newRegistrationParticipant nr
        liftIO $ execute conn
            "INSERT INTO registrations (tournament_id, participant_id, status) \
            \VALUES (?, ?, ?)"
            ( tidInt
            , pidInt
            , registrationStatusToText Confirmed
            )
        rowId <- liftIO $ lastInsertRowId conn
        pure (RegistrationId (fromIntegral rowId))

    getRegistration :: RegistrationId -> SQLiteM Registration
    getRegistration rid@(RegistrationId ridInt) = do
        conn <- asks envConnection
        rows <- liftIO $
            (query conn
                "SELECT tournament_id, participant_id, status \
                \FROM registrations WHERE id = ?"
                (Only ridInt)
             :: IO [(Int, Int, String)])
        case rows of
            [(tidInt, pidInt, statusText)] -> do
                status      <- liftIO $ textToRegistrationStatus statusText
                participant <- getParticipant (ParticipantId pidInt)
                pure Registration
                    { registrationId          = rid
                    , registrationTournament  = TournamentId tidInt
                    , registrationParticipant = participant
                    , registrationStatus      = status
                    }
            [] -> liftIO $ throwIO (NotFound ("Registration not found: " ++ show ridInt))
            _  -> liftIO $ throwIO (StorageFailure ("Multiple registrations with id " ++ show ridInt))

    deleteRegistration :: RegistrationId -> SQLiteM ()
    deleteRegistration (RegistrationId ridInt) = do
        conn <- asks envConnection
        liftIO $ execute conn
            "DELETE FROM registrations WHERE id = ?"
            (Only ridInt)
        n <- liftIO $ changes conn
        when (n == 0) $
            liftIO $ throwIO (NotFound ("Registration not found: " ++ show ridInt))

    listRegistrations :: TournamentId -> SQLiteM [Registration]
    listRegistrations (TournamentId tidInt) = do
        conn <- asks envConnection
        rows <- liftIO $
            (query conn
                "SELECT id, participant_id, status \
                \FROM registrations WHERE tournament_id = ?"
                (Only tidInt)
             :: IO [(Int, Int, String)])
        mapM hydrate rows
      where
        hydrate (ridInt, pidInt, statusText) = do
            status      <- liftIO $ textToRegistrationStatus statusText
            participant <- getParticipant (ParticipantId pidInt)
            pure Registration
                { registrationId          = RegistrationId ridInt
                , registrationTournament  = TournamentId tidInt
                , registrationParticipant = participant
                , registrationStatus      = status
                }