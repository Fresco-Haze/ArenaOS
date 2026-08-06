module Application.UseCases.UpdateProfile
  ( UpdateProfileRequest(..)
  , UpdateProfileError(..)
  , updateProfile
  ) where

import Domain.User (User(..), Username, Email)
import Domain.Ids (UserId)
import Engine.User (validateUsername, validateEmail, UserError(..))
import Shell.Persistence.Port (UserRepository(..))

data UpdateProfileRequest = UpdateProfileRequest
    { updateProfileUserId      :: UserId
    , updateProfileNewUsername :: Maybe Username
    , updateProfileNewEmail    :: Maybe Email
    }
    deriving (Eq, Show)

data UpdateProfileError
    = ProfileUserNotFound
    | InvalidProfileUsername UserError
    | InvalidProfileEmail UserError
    | ProfileUsernameTaken
    | ProfileEmailTaken
    deriving (Eq, Show)

updateProfile
    :: (Monad m, UserRepository m)
    => UpdateProfileRequest
    -> m (Either UpdateProfileError ())
updateProfile req = do
    maybeUser <- findUserById (updateProfileUserId req)
    case maybeUser of
        Nothing -> pure (Left ProfileUserNotFound)
        Just _  -> updateUsernameStep
  where
    updateUsernameStep =
        case updateProfileNewUsername req of
            Nothing -> updateEmailStep
            Just newUsername ->
                case validateUsername newUsername of
                    Left err -> pure (Left (InvalidProfileUsername err))
                    Right _  -> do
                        existing <- findUserByUsername newUsername
                        case existing of
                            Just other | userId other /= updateProfileUserId req ->
                                pure (Left ProfileUsernameTaken)
                            _ -> do
                                updateUsername (updateProfileUserId req) newUsername
                                updateEmailStep

    updateEmailStep =
        case updateProfileNewEmail req of
            Nothing -> pure (Right ())
            Just newEmail ->
                case validateEmail newEmail of
                    Left err -> pure (Left (InvalidProfileEmail err))
                    Right _  -> do
                        existing <- findUserByEmail newEmail
                        case existing of
                            Just other | userId other /= updateProfileUserId req ->
                                pure (Left ProfileEmailTaken)
                            _ -> do
                                updateEmail (updateProfileUserId req) newEmail
                                pure (Right ())