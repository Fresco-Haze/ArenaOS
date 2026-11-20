-- Domain.TeamProfile
-- Optional details about a team. Empty strings mean "not set". Pure data only.
module Domain.TeamProfile
    ( Recruitment(..)
    , TeamProfile(..)
    ) where

data Recruitment = OpenTryouts | InviteOnly
    deriving (Show, Eq)

data TeamProfile = TeamProfile
    { profileTag         :: String
    , profileGame        :: String
    , profileRegion      :: String
    , profileRecruitment :: Recruitment
    } deriving (Show, Eq)