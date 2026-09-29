{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A Yesod 'SessionBackend' for Cloudflare Workers, on WebCrypto
-- AES-256-GCM.
--
-- @
-- makeSessionBackend app =
--   Just \<$\> cloudflareSessionBackend (SessionKeys current olds) 120
-- @
--
-- Behaves like yesod-core's @clientSessionBackend@: the session lives in an
-- encrypted @_SESSION@ cookie (@HttpOnly; Path=/; Expires@), the idle
-- timeout restarts on every request, and an unreadable cookie is an empty
-- session. Differences: the current time is read per request instead of
-- from a background cache thread, and a session too large for a cookie is
-- an error instead of a cookie the browser silently drops.
--
-- If a request carries several @_SESSION@ cookies (for example one per
-- Path or Domain), each is opened, and the session is used only when
-- exactly one of them opens (authenticates under some key and has not
-- expired); otherwise the session is empty. This is yesod-core's rule.
--
-- Keys are Secret strings of at least 32 bytes. Each must be a random
-- secret, such as the output of @openssl rand -base64 32@, not a passphrase:
-- keys go through HKDF, which is not a password hash and does nothing to
-- slow down guessing. The first key encrypts; all are tried, in order, to
-- decrypt, so rotating means moving the old key to 'oldKeys' until existing
-- sessions have been rewritten. IVs are random 96-bit values, so rotate
-- each key well before it has encrypted 2^32 sessions; that only matters
-- for very high traffic.
--
-- The timeout is in minutes and must be at least 1.
module Yesod.Cloudflare.Session
  ( SessionKeys (..)
  , cloudflareSessionBackend
  , SessionKeyTooShort (..)
  , SessionTooLarge (..)
  ) where

import           Control.Exception             (Exception (..), throwIO)
import           Control.Monad                 (forM_, unless, when)
import qualified Data.ByteString               as B
import qualified Data.ByteString.Base64.URL    as B64U
import qualified Data.Map.Strict               as Map
import           Data.Maybe                    (catMaybes)
import           Data.Text                     (Text)
import qualified Data.Text.Encoding            as TE
import           Data.Time.Clock.POSIX         (getPOSIXTime,
                                                posixSecondsToUTCTime)
import           Data.Word                     (Word64)
import qualified Network.Wai                   as W
import           Web.Cookie                    (defaultSetCookie, parseCookies,
                                                setCookieExpires,
                                                setCookieHttpOnly,
                                                setCookieName, setCookiePath,
                                                setCookieValue)
import           Yesod.Core                    (Header (..), SessionBackend (..),
                                                SessionMap)

import           Cloudflare.Workers.Crypto
import           Yesod.Cloudflare.Session.Codec

data SessionKeys = SessionKeys
  { currentKey :: Text
    -- ^ Encrypts every session written.
  , oldKeys    :: [Text]
    -- ^ Only decrypt, tried after 'currentKey'.
  }

-- | A key shorter than 32 bytes (UTF-8).
data SessionKeyTooShort = SessionKeyTooShort
  deriving (Show)

instance Exception SessionKeyTooShort where
  displayException _ = "session keys must be at least 32 bytes"

-- | The encoded cookie value, in bytes, exceeded 'maxCookieBytes'.
newtype SessionTooLarge = SessionTooLarge Int
  deriving (Show)

instance Exception SessionTooLarge where
  displayException (SessionTooLarge n) =
    "session cookie too large: " <> show n <> " bytes (limit " <> show maxCookieBytes <> ")"

cookieName :: B.ByteString
cookieName = "_SESSION"

version :: B.ByteString
version = B.singleton 1

-- | Additional authenticated data: binds the ciphertext to this cookie and
-- format version.
aad :: B.ByteString
aad = cookieName <> version

-- | Browsers drop cookies above about 4 KiB, name and attributes included.
maxCookieBytes :: Int
maxCookieBytes = 4000

-- | Derive the keys once, then build the backend. Before deriving
-- anything, throws an 'IOError' if the timeout is under 1 minute and
-- 'SessionKeyTooShort' if a key is under 32 bytes.
cloudflareSessionBackend
  :: SessionKeys
  -> Int -- ^ Idle timeout in minutes, at least 1.
  -> IO SessionBackend
cloudflareSessionBackend keys minutes = do
  unless (minutes >= 1) $
    ioError (userError "Yesod.Cloudflare.Session: timeout must be at least 1 minute")
  forM_ (currentKey keys : oldKeys keys) $ \k ->
    when (B.length (TE.encodeUtf8 k) < 32) (throwIO SessionKeyTooShort)
  current <- derive (currentKey keys)
  olds <- mapM derive (oldKeys keys)
  pure SessionBackend {sbLoadSession = load current (current : olds)}
  where
    derive k = hkdfAesGcmKey (TE.encodeUtf8 k) "yesod-cloudflare" "yesod-cloudflare session v1"

    load current decryptKeys req = do
      now <- nowSeconds
      opened <- catMaybes <$> mapM (openCookie decryptKeys now) (requestCookies req)
      let session = case opened of
            [s] -> s
            _   -> Map.empty
      pure (session, save current)

    save current session = do
      now <- nowSeconds
      let expires = now + fromIntegral minutes * 60
      value <- sealCookie current expires session
      when (B.length value > maxCookieBytes) (throwIO (SessionTooLarge (B.length value)))
      pure
        [ AddCookie
            defaultSetCookie
              { setCookieName = cookieName
              , setCookieValue = value
              , setCookiePath = Just "/"
              , setCookieExpires = Just (posixSecondsToUTCTime (fromIntegral expires))
              , setCookieHttpOnly = True
              }
        ]

nowSeconds :: IO Word64
nowSeconds = floor <$> getPOSIXTime

-- | Every @_SESSION@ value, across all Cookie headers.
requestCookies :: W.Request -> [B.ByteString]
requestCookies req =
  [ v
  | (name, raw) <- W.requestHeaders req
  , name == "Cookie"
  , (k, v) <- parseCookies raw
  , k == cookieName
  ]

-- | The session in one cookie value, or 'Nothing' on any failure: bad
-- encoding, unknown version, no key that authenticates, malformed
-- plaintext, expiry passed.
openCookie :: [AesGcmKey] -> Word64 -> B.ByteString -> IO (Maybe SessionMap)
openCookie decryptKeys now value =
  case B64U.decodeUnpadded value of
    Right raw
      | B.length raw >= 1 + 12 + 16
      , B.take 1 raw == version ->
          tryKeys (B.take 12 (B.drop 1 raw)) (B.drop 13 raw) decryptKeys
    _ -> pure Nothing
  where
    tryKeys _ _ [] = pure Nothing
    tryKeys iv ct (k : ks) =
      aesGcmDecrypt k iv aad ct >>= \case
        Nothing -> tryKeys iv ct ks
        Just plaintext -> pure $ case decodePayload plaintext of
          Just (expires, session) | expires > now -> Just session
          _ -> Nothing

sealCookie :: AesGcmKey -> Word64 -> SessionMap -> IO B.ByteString
sealCookie key expires session = do
  iv <- randomBytes 12
  ciphertext <- aesGcmEncrypt key iv aad (encodePayload expires session)
  pure (B64U.encodeUnpadded (version <> iv <> ciphertext))
