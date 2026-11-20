-- Domain.Substitution
-- A request to swap one player on a locked team roster for another. Pure data only.
module Domain.Substitution
    ( SubstitutionStatus(..)
    , Substitution(..)
    ) where

import Domain.Ids (UserId)
import Domain.Participant (TeamName)
import Domain.Tournament (TournamentId)

data SubstitutionStatus = SubPending | SubApproved | SubDeclined
    deriving (Show, Eq)

data Substitution = Substitution
    { subId          :: Int
    , subTeam        :: TeamName
    , subTournament  :: TournamentId
    , subOutPlayer   :: String
    , subInUser      :: UserId
    , subRequestedBy :: UserId
    , subStatus      :: SubstitutionStatus
    }