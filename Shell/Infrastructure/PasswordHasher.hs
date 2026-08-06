{-# LANGUAGE InstanceSigs #-}

module Shell.Infrastructure.PasswordHasher () where

import Shell.Persistence.Port (PasswordHasher(..))
import Shell.Persistence.SQLite.Connection (SQLiteM)
import Shell.Persistence.SQLite.Error (PersistenceError(..))
import Domain.User (PasswordHash(..))

import Crypto.Argon2
  ( HashOptions(..)
  , Argon2Variant(..)
  , Argon2Status(..)
  , defaultHashOptions
  , hashEncoded
  , verifyEncoded
  )
import System.Entropy (getEntropy)
import Control.Exception (throwIO)
import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Short as TS

-- Stored PasswordHash values use the PHC encoded format. Each value
-- is self-contained and carries its own algorithm, version,
-- parameters, and salt -- no separate salt column or config is
-- persisted anywhere else. See ADR-007 for the failure-propagation
-- boundary this instance relies on (HashingFailure).

saltLength :: Int
saltLength = 16

instance PasswordHasher SQLiteM where
    hashPassword :: Text -> SQLiteM PasswordHash
    hashPassword pw = do
        salt <- liftIO (getEntropy saltLength)
        let passwordBytes = TE.encodeUtf8 pw
            opts = defaultHashOptions { hashVariant = Argon2id }
        case hashEncoded opts passwordBytes salt of
            Left status ->
                liftIO $ throwIO $ HashFailure (show status)
            Right encoded ->
                pure (PasswordHash (TS.toText encoded))

    verifyPassword :: Text -> PasswordHash -> SQLiteM Bool
    verifyPassword pw (PasswordHash encodedText) =
        case verifyEncoded (TS.fromText encodedText) (TE.encodeUtf8 pw) of
            Argon2Ok -> pure True
            _        -> pure False