module Application.UseCases.LogoutUser
  ( logoutUser
  ) where

import Shell.Auth.Session (clearSession)

logoutUser :: IO ()
logoutUser = clearSession