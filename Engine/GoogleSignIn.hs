-- Engine.GoogleSignIn: what to do when someone signs in with Google.
-- Pure: no database, no network. The caller looks things up and passes them in.
--
-- Rules, in order:
--  1. The Google id is already linked to an account:
--       active account                -> log in as that user
--       suspended or deactivated      -> refused, naming the status
--  2. Not linked yet:
--       Google says the email is not verified     -> refused
--       the email belongs to ANY existing account -> refused (no linking, no takeover)
--       otherwise                                 -> a new user, who must choose a username
module Engine.GoogleSignIn
  ( GoogleIdentity(..)
  , GoogleRefusal(..)
  , SignInDecision(..)
  , decideGoogleSignIn
  ) where

import Data.Text (Text)
import Domain.Ids (UserId)
import Domain.User (User(..), AccountStatus(..))

-- What Google told us about the person who just signed in.
data GoogleIdentity = GoogleIdentity
  { giSubject       :: Text
  , giEmail         :: Text
  , giEmailVerified :: Bool
  , giName          :: Maybe Text
  } deriving (Eq, Show)

data GoogleRefusal
  = EmailNotVerified
  | EmailAlreadyUsed
  | AccountNotActive AccountStatus
  deriving (Eq, Show)

data SignInDecision
  = LogInAs UserId
  | NeedsUsername
  | Refuse GoogleRefusal
  deriving (Eq, Show)

-- Arguments: the identity, the user already linked to its Google id (if any),
-- and the user who owns its email address (if any).
decideGoogleSignIn :: GoogleIdentity -> Maybe User -> Maybe User -> SignInDecision
decideGoogleSignIn ident linked byEmail =
  case linked of
    Just user
      | accountStatus user == Active -> LogInAs (userId user)
      | otherwise                    -> Refuse (AccountNotActive (accountStatus user))
    Nothing
      | not (giEmailVerified ident)  -> Refuse EmailNotVerified
      | otherwise                    ->
          case byEmail of
            Just _  -> Refuse EmailAlreadyUsed
            Nothing -> NeedsUsername
