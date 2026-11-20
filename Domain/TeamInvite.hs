-- Domain.TeamInvite
-- A team owner's invitation to a registered player. Pure data only.
module Domain.TeamInvite
    ( TeamInviteStatus(..)
    ) where

data TeamInviteStatus = InvitePending | InviteAccepted | InviteDeclined
    deriving (Show, Eq)