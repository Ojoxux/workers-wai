{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}

-- | Checks the packages vendored under haskell/vendor against published
-- known-answer vectors. Driven by test/vendor.test.mjs; not an example to
-- copy.
module Main (main) where

import           Crypto.Cipher.AES              (AES128)
import           Crypto.Cipher.Types            (cipherInit, ecbEncrypt)
import           Crypto.Error                   (throwCryptoError)
import           Crypto.Hash                    (SHA256 (..), hashWith)
import           Crypto.MAC.HMAC                (HMAC, hmac)
import qualified Crypto.PubKey.Curve25519       as X25519
import qualified Crypto.PubKey.Curve448         as X448
import           Crypto.Random                  (getRandomBytes)
import qualified Data.ByteArray                 as BA
import qualified Data.ByteArray.Encoding        as BAE
import qualified Data.ByteString                as B
import qualified Data.ByteString.Char8          as BC
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import qualified Data.Text.Encoding             as TE
import           Network.Wai.Handler.Cloudflare (runCloudflare)
import           Yesod.Core

data App = App

mkYesod "App" [parseRoutes|
/vectors VectorsR GET
/random  RandomR  GET
|]

instance Yesod App where
  makeSessionBackend _ = pure Nothing

-- | A named check: expected and actual, both as printable bytes.
type Check = (Text, B.ByteString, B.ByteString)

-- | "ok <count>" when every check passes, otherwise one line per failure.
getVectorsR :: Handler Text
getVectorsR = liftIO (report <$> sequence checks)

checks :: [IO Check]
checks = cryptoChecks

report :: [Check] -> Text
report cs =
  case [ name <> ": expected " <> TE.decodeUtf8 e <> ", got " <> TE.decodeUtf8 a
       | (name, e, a) <- cs
       , e /= a
       ] of
    [] -> "ok " <> T.pack (show (length cs))
    failures -> T.intercalate "\n" failures

cryptoChecks :: [IO Check]
cryptoChecks =
  [ pure
      ( "sha256 abc"
      , "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
      , hex (hashWith SHA256 ("abc" :: B.ByteString))
      )
  , pure
      ( "aes128 fips-197 c.1"
      , "69c4e0d86a7b0430d8cdb78070b4c55a"
      , hex (ecbEncrypt aes (unhex "00112233445566778899aabbccddeeff"))
      )
  , pure
      ( "hmac-sha256 rfc4231 case 1"
      , "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
      , hex (hmac (B.replicate 20 0x0b) ("Hi There" :: B.ByteString) :: HMAC SHA256)
      )
  , pure
      ( "hmac-sha256 rfc4231 case 2"
      , "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
      , hex (hmac ("Jefe" :: B.ByteString) ("what do ya want for nothing?" :: B.ByteString) :: HMAC SHA256)
      )
  , pure
      ( "x25519 rfc7748 5.2"
      , "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552"
      , hex
          ( X25519.dh
              (throwCryptoError (X25519.publicKey (unhex "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c")))
              (throwCryptoError (X25519.secretKey (unhex "a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4")))
          )
      )
  , pure
      ( "x448 rfc7748 6.2"
      , "07fff4181ac6cc95ec1c16a94a0f74d12da232ce40a77552281d282bb60c0b56fd2464c335543936521c24403085d59a449a5037514a879d"
      , hex
          ( X448.dh
              (throwCryptoError (X448.publicKey (unhex "3eb7a829b0cd20f5bcfc0b599b6feccf6da4627107bdb0d4f345b43027d8b972fc3e34fb4232a13ca706dcb57aec3dae07bdc1c67bf33609")))
              (throwCryptoError (X448.secretKey (unhex "9a8f4925d1519f5775cf46b04b5800d4ee9ee8bae8bc5565d498c28dd9c9baf574a9419744897391006382a6f127ab1d9ac2d8c0a598726b")))
          )
      )
  , pure
      ( "memory constEq"
      , "True False"
      , BC.pack (show (BA.constEq abc abc) <> " " <> show (BA.constEq abc ("abd" :: B.ByteString)))
      )
  , pure ("memory convert", "616263", hex (BA.convert abc :: BA.Bytes))
  , pure
      ( "memory convert round trip"
      , "True"
      , BC.pack (show (BA.convert (BA.convert abc :: BA.Bytes) == abc))
      )
  ]
  where
    aes = throwCryptoError (cipherInit (B.pack [0 .. 15])) :: AES128
    abc = "abc" :: B.ByteString

getRandomR :: Handler Text
getRandomR = liftIO (TE.decodeUtf8 . hex <$> (getRandomBytes 32 :: IO B.ByteString))

hex :: (BA.ByteArrayAccess a) => a -> B.ByteString
hex = BAE.convertToBase BAE.Base16

unhex :: B.ByteString -> B.ByteString
unhex = either error id . BAE.convertFromBase BAE.Base16

foreign export javascript "workerMain" main :: IO ()

main :: IO ()
main = toWaiAppPlain App >>= runCloudflare
