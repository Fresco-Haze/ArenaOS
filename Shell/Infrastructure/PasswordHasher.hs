{-# LANGUAGE InstanceSigs #-}

module Shell.Infrastructure.PasswordHasher
  ( hashPasswordIO
  , verifyPasswordPure
  ) where

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
-- boundary this instance relies on (HashFailure).
--
-- hashPasswordIO / verifyPasswordPure exist so the API can run the
-- expensive Argon2 work OUTSIDE the global DB lock.

saltLength :: Int
saltLength = 16

hashPasswordIO :: Text -> IO PasswordHash
hashPasswordIO pw = do
    salt <- getEntropy saltLength
    let passwordBytes = TE.encodeUtf8 pw
        opts = defaultHashOptions { hashVariant = Argon2id }
    case hashEncoded opts passwordBytes salt of
        Left status ->
            throwIO (HashFailure (show status))
        Right encoded ->
            pure (PasswordHash (TS.toText encoded))

verifyPasswordPure :: Text -> PasswordHash -> Bool
verifyPasswordPure pw (PasswordHash encodedText) =
    case verifyEncoded (TS.fromText encodedText) (TE.encodeUtf8 pw) of
        Argon2Ok -> True
        _        -> False

instance PasswordHasher SQLiteM where
    hashPassword :: Text -> SQLiteM PasswordHash
    hashPassword = liftIO . hashPasswordIO

    verifyPassword :: Text -> PasswordHash -> SQLiteM Bool
    verifyPassword pw h = pure (verifyPasswordPure pw h)