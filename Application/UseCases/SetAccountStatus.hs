module Application.UseCases.SetAccountStatus
  ( SetAccountStatusRequest(..)
  , SetAccountStatusError(..)
  , setAccountStatus
  ) where

import Domain.User (AccountStatus)
import Domain.Ids (UserId)
import Shell.Persistence.Port (UserRepository(..))

data SetAccountStatusRequest = SetAccountStatusRequest
    { statusUserId :: UserId
    , statusNew    :: AccountStatus
    }
    deriving (Eq, Show)

data SetAccountStatusError
    = StatusUserNotFound
    deriving (Eq, Show)

setAccountStatus
    :: (Monad m, UserRepository m)
    => SetAccountStatusRequest
    -> m (Either SetAccountStatusError ())
setAccountStatus req = do
    maybeUser <- findUserById (statusUserId req)
    case maybeUser of
        Nothing -> pure (Left StatusUserNotFound)
        Just _  -> do
            updateAccountStatus (statusUserId req) (statusNew req)
            pure (Right ())