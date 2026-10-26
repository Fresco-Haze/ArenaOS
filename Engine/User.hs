module Engine.User
  ( UserError(..)
  , validateUsername
  , validateEmail
  , validatePasswordHash
  , validateUser
  , validateRawPassword
  , FullNameError(..)
  , validateFullName
  , BioError(..)
  , validateBio
  ) where

import Domain.User (Username(..), Email(..), PasswordHash(..), User(..))
import qualified Data.Text as T
import Data.Char (isAlphaNum)
import Data.Text (Text)

data UserError
  = InvalidUsername Username
  | InvalidEmail Email
  | EmptyPasswordHash
  | EmptyPassword
  | PasswordTooShort
  deriving (Eq, Show)

validateUsername :: Username -> Either UserError Username
validateUsername u@(Username t)
  | len < 3 || len > 30        = Left (InvalidUsername u)
  | not (T.all isValidChar t)  = Left (InvalidUsername u)
  | otherwise                  = Right u
  where
    len = T.length t
    isValidChar c = isAlphaNum c || c == '_'

validateEmail :: Email -> Either UserError Email
validateEmail e@(Email t)
  | atCount /= 1 || T.null before || T.null domain = Left (InvalidEmail e)
  | otherwise                                      = Right e
  where
    at = T.pack "@"
    atCount = T.count at t
    (before, after) = T.breakOn at t
    domain = T.drop 1 after

validatePasswordHash :: PasswordHash -> Either UserError PasswordHash
validatePasswordHash h@(PasswordHash t)
  | T.null t  = Left EmptyPasswordHash
  | otherwise = Right h

validateUser :: User -> Either UserError User
validateUser u = do
  _ <- validateUsername (username u)
  _ <- validateEmail (email u)
  _ <- validatePasswordHash (passwordHash u)
  pure u

validateRawPassword :: Text -> Either UserError Text
validateRawPassword t
  | T.null t          = Left EmptyPassword
  | T.length t < 8    = Left PasswordTooShort
  | otherwise         = Right t

data FullNameError = FullNameTooLong
  deriving (Eq, Show)

-- Trimmed; blank means "no name"; at most 60 characters.
validateFullName :: Text -> Either FullNameError (Maybe Text)
validateFullName raw
  | T.null s        = Right Nothing
  | T.length s > 60 = Left FullNameTooLong
  | otherwise       = Right (Just s)
  where s = T.strip raw

data BioError = BioTooLong
  deriving (Eq, Show)

-- Trimmed; blank means "no bio"; at most 160 characters.
validateBio :: Text -> Either BioError (Maybe Text)
validateBio raw
  | T.null s         = Right Nothing
  | T.length s > 160 = Left BioTooLong
  | otherwise        = Right (Just s)
  where s = T.strip raw