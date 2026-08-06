module Application.UseCases.LoginUser
  ( LoginUserRequest(..)
  , LoginUserError(..)
  , loginUser
  ) where

import Data.Text (Text)
import Domain.User (User(..), Username, passwordHash)
import Shell.Persistence.Port (UserRepository(..), PasswordHasher(..))

data LoginUserRequest = LoginUserRequest
  { loginUsername :: Username
  , loginPassword :: Text  -- raw, compared via PasswordHasher, never stored
  }

data LoginUserError
  = InvalidCredentials
  deriving (Eq, Show)

loginUser
  :: ( Monad m
     , UserRepository m
     , PasswordHasher m
     )
  => LoginUserRequest
  -> m (Either LoginUserError User)
loginUser req = do
  maybeUser <- findUserByUsername (loginUsername req)
  case maybeUser of
    Nothing ->
      -- SECURITY (deferred, not forgotten): no dummy-hash verification on
      -- this branch yet, so a timing side-channel exists (unknown-username
      -- rejection is faster than wrong-password rejection). Mitigation needs
      -- a config-managed constant hash, which doesn't exist yet in v0.2.
      -- Revisit when config/session infrastructure is introduced.
      pure (Left InvalidCredentials)
    Just user -> do
      ok <- verifyPassword (loginPassword req) (passwordHash user)
      pure $ if ok then Right user else Left InvalidCredentials