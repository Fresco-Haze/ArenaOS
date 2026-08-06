module Engine.User
  ( UserError(..)
  , validateUsername
  , validateEmail
  , validatePasswordHash
  , validateUser
  , validateRawPassword
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
  | T.null t  = Left EmptyPassword
  | otherwise = Right t