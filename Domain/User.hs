module Domain.User
  ( Username(..)
  , Email(..)
  , PasswordHash(..)
  , User(..)
  , AccountStatus(..)
  ) where

import Domain.Ids (UserId(..))
import Data.Text (Text)

newtype Username = Username { unUsername :: Text } deriving (Show, Eq)
newtype Email = Email { unEmail :: Text } deriving (Show, Eq)
newtype PasswordHash = PasswordHash { unPasswordHash :: Text } deriving (Show, Eq)

data User = User
  { userId       :: UserId
  , username     :: Username
  , email        :: Email
  , passwordHash :: PasswordHash
  , accountStatus :: AccountStatus
  } deriving (Show, Eq)

data AccountStatus = Active | Suspended | Deactivated
  deriving (Show, Eq)