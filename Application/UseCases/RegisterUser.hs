module Application.UseCases.RegisterUser
  ( RegisterUserRequest(..)
  , RegisterUserError(..)
  , registerUser
  , validateRegistration
  , registerWithHash
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

-- | Pure validation; safe to run before taking the DB lock.
validateRegistration :: RegisterUserRequest -> Either RegisterUserError ()
validateRegistration req = either (Left . InvalidUser) Right $ do
    _ <- validateUsername (registerUsername req)
    _ <- validateEmail (registerEmail req)
    _ <- validateRawPassword (registerPassword req)
    pure ()

checkUnique :: (Monad m, UserRepository m)
            => RegisterUserRequest -> m (Either RegisterUserError ())
checkUnique req = do
    existingByName <- findUserByUsername (registerUsername req)
    case existingByName of
        Just _  -> pure (Left UsernameTaken)
        Nothing -> do
            existingByEmail <- findUserByEmail (registerEmail req)
            case existingByEmail of
                Just _  -> pure (Left EmailTaken)
                Nothing -> pure (Right ())

createWithHash :: (Monad m, UserRepository m)
               => RegisterUserRequest -> PasswordHash -> m (Either RegisterUserError User)
createWithHash req hashed = do
    let nu = NewUser
            { newUserUsername     = registerUsername req
            , newUserEmail        = registerEmail req
            , newUserPasswordHash = hashed
            }
    uid <- createUser nu
    pure $ Right User
        { userId        = uid
        , username      = registerUsername req
        , email         = registerEmail req
        , passwordHash  = hashed
        , accountStatus = Active
        }

-- | Uniqueness check + insert with a hash computed elsewhere (outside the lock).
registerWithHash
    :: (Monad m, UserRepository m)
    => RegisterUserRequest -> PasswordHash -> m (Either RegisterUserError User)
registerWithHash req hashed = do
    free <- checkUnique req
    case free of
        Left err -> pure (Left err)
        Right () -> createWithHash req hashed

registerUser
    :: (Monad m, UserRepository m, PasswordHasher m)
    => RegisterUserRequest
    -> m (Either RegisterUserError User)
registerUser req =
    case validateRegistration req of
        Left err -> pure (Left err)
        Right () -> do
            free <- checkUnique req
            case free of
                Left err -> pure (Left err)
                Right () -> do
                    hashed <- hashPassword (registerPassword req)
                    createWithHash req hashed