module Application.UseCases.LoginUser
  ( LoginUserRequest(..)
  , LoginUserError(..)
  , loginUser
  , lookupForLogin
  , finishLogin
  ) where

import Data.Text (Text)
import Domain.User (User(..), Username, passwordHash, AccountStatus(..))
import Shell.Persistence.Port (UserRepository(..), PasswordHasher(..))

data LoginUserRequest = LoginUserRequest
  { loginUsername :: Username
  , loginPassword :: Text  -- raw, compared via PasswordHasher, never stored
  }

data LoginUserError
  = InvalidCredentials
  | AccountNotActive AccountStatus
  deriving (Eq, Show)

-- | Step 1 (needs the DB): find the user.
lookupForLogin :: UserRepository m => LoginUserRequest -> m (Maybe User)
lookupForLogin req = findUserByUsername (loginUsername req)

-- | Step 3 (pure): decide the outcome. The password check comes first,
-- so a wrong password on a suspended account is still InvalidCredentials
-- and account state never leaks to someone who doesn't know the password.
finishLogin :: Maybe User -> Bool -> Either LoginUserError User
finishLogin Nothing _ = Left InvalidCredentials
finishLogin (Just user) ok
  | not ok                       = Left InvalidCredentials
  | accountStatus user /= Active = Left (AccountNotActive (accountStatus user))
  | otherwise                    = Right user

loginUser
  :: ( Monad m
     , UserRepository m
     , PasswordHasher m
     )
  => LoginUserRequest
  -> m (Either LoginUserError User)
loginUser req = do
  maybeUser <- lookupForLogin req
  ok <- case maybeUser of
    Nothing   -> pure False
    Just user -> verifyPassword (loginPassword req) (passwordHash user)
  pure (finishLogin maybeUser ok)