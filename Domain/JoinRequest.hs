-- Domain.JoinRequest
-- A player's request to join a tournament that requires organizer approval.
module Domain.JoinRequest
    ( JoinRequestStatus(..)
    ) where

data JoinRequestStatus = JoinPending | JoinApproved | JoinDeclined
    deriving (Show, Eq)