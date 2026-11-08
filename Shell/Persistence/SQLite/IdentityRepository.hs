{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}
module Shell.Persistence.SQLite.IdentityRepository () where
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.Text (Text)
import Database.SQLite.Simple (Only(..), changes, execute, query)
import Domain.Ids (UserId(..))
import Shell.Persistence.Port (IdentityRepository(..), HandoffPayload(..))
import Shell.Persistence.SQLite.Connection (SQLiteEnv(..), SQLiteM)
instance IdentityRepository SQLiteM where
  findIdentityUser :: Text -> Text -> SQLiteM (Maybe UserId)
  findIdentityUser provider subject = do
    conn <- asks envConnection
    rows <- liftIO (query conn "SELECT user_id FROM user_identities WHERE provider = ? AND subject = ?" (provider, subject) :: IO [Only Int])
    pure (case rows of
            (Only u : _) -> Just (UserId u)
            []           -> Nothing)
  linkIdentity :: UserId -> Text -> Text -> SQLiteM Bool
  linkIdentity (UserId uid) provider subject = do
    conn <- asks envConnection
    liftIO $ execute conn "INSERT OR IGNORE INTO user_identities (provider, subject, user_id, created_at) VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))" (provider, subject, uid)
    n <- liftIO (changes conn)
    pure (n > 0)
  createHandoff :: Text -> HandoffPayload -> Int -> SQLiteM ()
  createHandoff codeHash payload expiresAt = do
    conn <- asks envConnection
    case payload of
      HandoffLogin (UserId u) ->
        liftIO $ execute conn "INSERT INTO google_handoffs (code_hash, user_id, expires_at) VALUES (?, ?, ?)" (codeHash, u, expiresAt)
      HandoffSignUp sub em nm ->
        liftIO $ execute conn "INSERT INTO google_handoffs (code_hash, subject, email, name, expires_at) VALUES (?, ?, ?, ?, ?)" (codeHash, sub, em, nm, expiresAt)
  consumeHandoff :: Text -> Int -> SQLiteM (Maybe HandoffPayload)
  consumeHandoff codeHash now = do
    conn <- asks envConnection
    liftIO $ execute conn "UPDATE google_handoffs SET used_at = ? WHERE code_hash = ? AND used_at IS NULL AND expires_at > ?" (now, codeHash, now)
    n <- liftIO (changes conn)
    if n == 0 then pure Nothing else do
      rows <- liftIO (query conn "SELECT user_id, subject, email, name FROM google_handoffs WHERE code_hash = ?" (Only codeHash) :: IO [(Maybe Int, Maybe Text, Maybe Text, Maybe Text)])
      pure (case rows of
              ((Just u, _, _, _) : _)             -> Just (HandoffLogin (UserId u))
              ((Nothing, Just s, Just e, nm) : _) -> Just (HandoffSignUp s e nm)
              _                                   -> Nothing)
  purgeExpiredHandoffs :: Int -> SQLiteM ()
  purgeExpiredHandoffs now = do
    conn <- asks envConnection
    liftIO $ execute conn "DELETE FROM google_handoffs WHERE expires_at <= ? OR used_at IS NOT NULL" (Only now)
