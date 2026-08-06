module Application.UseCases.RegisterUser
  ( RegisterUserRequest(..)
  , RegisterUserError(..)
  , registerUser
  ) where

import Domain.User (User(..), Username, Email, PasswordHash, AccountStatus(..))
import Engine.User (UserError(..), validateUsername, validateEmail, validateRawPassword)
import Shell.Persistence.Port (UserRepository(..), NewUser(..), PasswordHasher(..))
import Data.Text (Text)

data RegisterUserRequest = RegisterUserRequest
    { registerUsername :: Username
    , registerEmail    :: Email
    , registerPassword :: Text
    }

data RegisterUserError
    = InvalidUser UserError
    | UsernameTaken
    | EmailTaken
    deriving (Eq, Show)

registerUser
    :: (Monad m, UserRepository m, PasswordHasher m)
    => RegisterUserRequest
    -> m (Either RegisterUserError User)
registerUser req = do
    case validated of
        Left err -> pure (Left (InvalidUser err))
        Right () -> checkUniqueness
  where
    validated = do
        _ <- validateUsername (registerUsername req)
        _ <- validateEmail (registerEmail req)
        _ <- validateRawPassword (registerPassword req)
        pure ()

    checkUniqueness = do
        existingByName <- findUserByUsername (registerUsername req)
        case existingByName of
            Just _  -> pure (Left UsernameTaken)
            Nothing -> do
                existingByEmail <- findUserByEmail (registerEmail req)
                case existingByEmail of
                    Just _  -> pure (Left EmailTaken)
                    Nothing -> doRegister

    doRegister = do
        hashed <- hashPassword (registerPassword req)
        let nu = NewUser
                { newUserUsername     = registerUsername req
                , newUserEmail        = registerEmail req
                , newUserPasswordHash = hashed
                }
        uid <- createUser nu
        pure $ Right User
            { userId       = uid
            , username     = registerUsername req
            , email        = registerEmail req
            , passwordHash = hashed
            , accountStatus = Active
            }