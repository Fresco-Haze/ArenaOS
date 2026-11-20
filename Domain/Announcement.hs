module Domain.Announcement
  ( Announcement(..)
  ) where

import Data.Text (Text)

-- A text update the tournament owner posted. The time is stored as an ISO text value.
data Announcement = Announcement
  { announcementId   :: Int
  , announcementBody :: Text
  , announcementAt   :: String
  } deriving (Eq, Show)