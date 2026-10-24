-- Domain.Notification
-- Pure data types only. A notification is addressed to one account.
module Domain.Notification
    ( NotificationKind(..)
    , Notification(..)
    ) where

import Domain.Ids (TournamentId(..))

data NotificationKind
    = NoteJoinRequested
    | NoteRequestApproved
    | NoteRequestDeclined
    | NoteTournamentStarted
    deriving (Show, Eq)

data Notification = Notification
    { notificationId             :: Int
    , notificationKind           :: NotificationKind
    , notificationTournamentId   :: TournamentId
    , notificationTournamentName :: String
    , notificationDetail         :: Maybe String
    , notificationAt             :: String
    , notificationRead           :: Bool
    } deriving (Show, Eq)