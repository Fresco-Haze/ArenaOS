module Application.UseCases.ChangePassword
  ( ChangePasswordRequest(..)
  , ChangePasswordError(..)
  , changePassword
  ) where

import Data.Text (Text)
import Domain.User (User(..),  passwordHash)
import Domain.Ids (UserId)
import Engine.User (validateRawPassword, UserError(..))
import Shell.Persistence.Port (UserRepository(..), PasswordHasher(..))

data ChangePasswordRequest = ChangePasswordRequest
    { changePasswordUserId  :: UserId
    , changePasswordCurrent :: Text
    , changePasswordNew     :: Text
    }
    deriving (Eq, Show)

data ChangePasswordError
    = UserNotFound
    | InvalidCurrentPassword
    | InvalidNewPassword UserError
    deriving (Eq, Show)

changePassword
    :: ( Monad m
       , UserRepository m
       , PasswordHasher m
       )
    => ChangePasswordRequest
    -> m (Either ChangePasswordError ())
changePassword req = do
    maybeUser <- findUserById (changePasswordUserId req)
    case maybeUser of
        Nothing -> pure (Left UserNotFound)
        Just user -> do
            valid <- verifyPassword (changePasswordCurrent req) (passwordHash user)
            if not valid
                then pure (Left InvalidCurrentPassword)
                else case validateRawPassword (changePasswordNew req) of
                    Left err -> pure (Left (InvalidNewPassword err))
                    Right _ -> do
                        newHash <- hashPassword (changePasswordNew req)
                        updatePasswordHash (changePasswordUserId req) newHash
                        pure (Right ())