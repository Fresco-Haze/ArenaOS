module Shell.Auth.Session
  ( SessionError(..)
  , saveSession
  , loadSession
  , clearSession
  ) where

import Control.Exception (IOException, catch, throwIO, try)
import Data.Char (isSpace)
import Data.List (dropWhileEnd)
import System.Directory (XdgDirectory(XdgConfig), createDirectoryIfMissing,
                          getXdgDirectory, removeFile)
import System.FilePath ((</>), takeDirectory)
import System.IO (readFile')
import System.IO.Error (isDoesNotExistError)
import Text.Read (readMaybe)

import Domain.Ids (UserId(..))  -- adjust to wherever unUserId/UserId actually live

data SessionError
  = InvalidSessionFile String
  deriving (Eq, Show)

sessionPath :: IO FilePath
sessionPath = do
  configDir <- getXdgDirectory XdgConfig "arenaos"
  pure (configDir </> "session")

trim :: String -> String
trim = dropWhileEnd isSpace . dropWhile isSpace

saveSession :: UserId -> IO ()
saveSession uid = do
  path <- sessionPath
  createDirectoryIfMissing True (takeDirectory path)
  writeFile path (show (unUserId uid))

loadSession :: IO (Either SessionError (Maybe UserId))
loadSession = do
  path <- sessionPath
  result <- try (readFile' path) :: IO (Either IOException String)
  case result of
    Left e
      | isDoesNotExistError e -> pure (Right Nothing)
      | otherwise             -> pure (Left (InvalidSessionFile (show e)))
    Right contents ->
      case readMaybe (trim contents) of
        Just n  -> pure (Right (Just (UserId n)))
        Nothing -> pure (Left (InvalidSessionFile ("unparseable contents: " <> contents)))

clearSession :: IO ()
clearSession = do
  path <- sessionPath
  removeFile path `catch` \e ->
    if isDoesNotExistError e then pure () else throwIO e