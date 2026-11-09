{-# LANGUAGE OverloadedStrings #-}
-- Engine.GoogleOAuth: the pure parts of the Google sign-in round trip.
-- No network, no database. The two HTTPS calls live elsewhere.
-- Google's endpoints are from its OpenID Connect reference page.
module Engine.GoogleOAuth
  ( GoogleConfig(..)
  , googleConfigFrom
  , googleAuthEndpoint
  , googleTokenEndpoint
  , googleUserInfoEndpoint
  , authorizeUrl
  , tokenRequestBody
  , parseTokenResponse
  , parseUserInfo
  , hashHandoffCode
  , cookieValue
  , stateMatches
  , stateCookieName
  , stateCookieHeader
  , clearStateCookieHeader
  , refusalCode
  ) where

import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (Value(..), eitherDecodeStrict)
import Data.Aeson.Types (Parser, parseEither, withObject, (.:), (.:?))
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import Engine.GoogleSignIn (GoogleIdentity(..), GoogleRefusal(..))

-- No Show instance on purpose: the secret must never be printed by accident.
data GoogleConfig = GoogleConfig
  { gcClientId     :: Text
  , gcClientSecret :: Text
  , gcRedirectUri  :: Text
  } deriving (Eq)

-- Nothing (Google is off) unless all three values are present.
googleConfigFrom :: Text -> Text -> Text -> Maybe GoogleConfig
googleConfigFrom cid sec uri
  | any T.null [c, s, u] = Nothing
  | otherwise            = Just (GoogleConfig c s u)
  where
    c = T.strip cid
    s = T.strip sec
    u = T.strip uri

googleAuthEndpoint, googleTokenEndpoint, googleUserInfoEndpoint :: Text
googleAuthEndpoint     = "https://accounts.google.com/o/oauth2/v2/auth"
googleTokenEndpoint    = "https://oauth2.googleapis.com/token"
googleUserInfoEndpoint = "https://openidconnect.googleapis.com/v1/userinfo"

-- Percent-encoding: letters, digits and - _ . ~ stay, every other UTF-8 byte becomes %XX.
enc :: Text -> Text
enc = T.concat . map byte . BS.unpack . TE.encodeUtf8
  where
    byte w
      | unreserved w = T.singleton (toEnum (fromIntegral w))
      | otherwise    = T.pack ['%', hexDigit (w `div` 16), hexDigit (w `mod` 16)]
    unreserved w = (w >= 48 && w <= 57) || (w >= 65 && w <= 90) || (w >= 97 && w <= 122)
                   || w == 45 || w == 95 || w == 46 || w == 126
    hexDigit n = ("0123456789ABCDEF" :: String) !! fromIntegral n

authorizeUrl :: GoogleConfig -> Text -> Text
authorizeUrl cfg st = googleAuthEndpoint <> "?" <> T.intercalate "&"
  [ "response_type=code"
  , "client_id=" <> enc (gcClientId cfg)
  , "redirect_uri=" <> enc (gcRedirectUri cfg)
  , "scope=" <> enc "openid email profile"
  , "state=" <> enc st
  , "prompt=select_account"
  ]

-- Form body for the token endpoint. Contains the client secret: never log it.
tokenRequestBody :: GoogleConfig -> Text -> BS.ByteString
tokenRequestBody cfg code = TE.encodeUtf8 (T.intercalate "&"
  [ "grant_type=authorization_code"
  , "code=" <> enc code
  , "client_id=" <> enc (gcClientId cfg)
  , "client_secret=" <> enc (gcClientSecret cfg)
  , "redirect_uri=" <> enc (gcRedirectUri cfg)
  ])

parseTokenResponse :: BS.ByteString -> Either Text Text
parseTokenResponse raw = do
  v <- either (Left . T.pack) Right (eitherDecodeStrict raw)
  tok <- either (Left . T.pack) Right (parseEither (withObject "token" (.: "access_token")) v)
  if T.null tok then Left "empty access token" else Right tok

userInfoParser :: Value -> Parser GoogleIdentity
userInfoParser = withObject "userinfo" $ \o -> do
  sub <- o .: "sub"
  mEmail <- o .:? "email"
  mVerified <- o .:? "email_verified"
  mName <- o .:? "name"
  let em = maybe "" T.strip mEmail
      verified = case mVerified of
        Just (Bool b)   -> b
        Just (String s) -> T.toLower s == "true"
        _               -> False
      nm = case fmap T.strip mName of
        Just n | not (T.null n) -> Just n
        _                       -> Nothing
  pure GoogleIdentity
    { giSubject       = sub
    , giEmail         = T.toLower em
    , giEmailVerified = verified
    , giName          = nm
    }

-- Fails closed: a missing or blank subject or email is refused.
parseUserInfo :: BS.ByteString -> Either Text GoogleIdentity
parseUserInfo raw = do
  v <- either (Left . T.pack) Right (eitherDecodeStrict raw)
  ident <- either (Left . T.pack) Right (parseEither userInfoParser v)
  validate ident
  where
    validate ident
      | T.null (giSubject ident)         = Left "empty subject"
      | T.length (giSubject ident) > 255 = Left "subject too long"
      | T.null (giEmail ident)           = Left "no email"
      | otherwise                        = Right ident

-- Hex SHA-256. Handoff codes are random 256-bit values, so a plain hash is enough.
hashHandoffCode :: Text -> Text
hashHandoffCode code = T.pack (show (hash (TE.encodeUtf8 code) :: Digest SHA256))

-- Value of a named cookie in a Cookie header. Empty values count as missing.
cookieValue :: Text -> Text -> Maybe Text
cookieValue name header =
  case [ T.drop 1 v | part <- T.splitOn ";" header, let (k, v) = T.breakOn "=" (T.strip part), k == name ] of
    (x : _) | not (T.null x) -> Just x
    _                        -> Nothing

stateMatches :: Maybe Text -> Maybe Text -> Bool
stateMatches (Just a) (Just b) = not (T.null a) && a == b
stateMatches _ _               = False

stateCookieName :: Text
stateCookieName = "sl_google_state"

-- The browser sees the /api prefix, so the cookie path includes it.
-- Secure is added only over https, so local http testing still works.
stateCookieHeader :: Bool -> Text -> Text
stateCookieHeader secure st = T.intercalate "; "
  ([stateCookieName <> "=" <> st, "Path=/api/auth/google", "HttpOnly", "SameSite=Lax", "Max-Age=600"] ++ ["Secure" | secure])

clearStateCookieHeader :: Bool -> Text
clearStateCookieHeader secure = T.intercalate "; "
  ([stateCookieName <> "=", "Path=/api/auth/google", "HttpOnly", "SameSite=Lax", "Max-Age=0"] ++ ["Secure" | secure])

-- Fixed codes for the /login?error=... redirect. Never Google's own text.
refusalCode :: GoogleRefusal -> Text
refusalCode EmailNotVerified     = "email_not_verified"
refusalCode EmailAlreadyUsed     = "email_in_use"
refusalCode (AccountNotActive _) = "account_not_active"