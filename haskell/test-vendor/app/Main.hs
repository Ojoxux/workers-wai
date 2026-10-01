{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}

-- | Checks the packages vendored under haskell/vendor against published
-- known-answer vectors. Driven by test/vendor.test.mjs; not an example to
-- copy.
module Main (main) where

import qualified Codec.CBOR.Decoding            as D
import qualified Codec.CBOR.Encoding            as E
import           Codec.CBOR.Read                (deserialiseFromBytes)
import           Codec.CBOR.Write               (toStrictByteString)
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
import qualified Data.ByteString.Lazy           as BL
import           Data.Int                       (Int64)
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import qualified Data.Text.Encoding             as TE
import           Data.Word                      (Word64)
import           Network.Wai.Handler.Cloudflare (runCloudflare)
import qualified Web.ClientSession              as CS
import           Yesod.Core

data App = App

mkYesod "App" [parseRoutes|
/vectors VectorsR GET
/random  RandomR  GET
/clientsession ClientSessionR GET
|]

instance Yesod App where
  makeSessionBackend _ = pure Nothing

-- | A named check: expected and actual, both as printable bytes.
type Check = (Text, B.ByteString, B.ByteString)

-- | "ok <count>" when every check passes, otherwise one line per failure.
getVectorsR :: Handler Text
getVectorsR = liftIO (report <$> sequence checks)

checks :: [IO Check]
checks = cryptoChecks <> map pure cborChecks

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

-- | RFC 8949 appendix A, plus the 32-bit boundaries the vendored cborg patch
-- touches. Each encode check compares bytes; each decode check decodes the
-- expected bytes back and compares the value.
cborChecks :: [Check]
cborChecks =
  concat
    [ word64 0 "00"
    , word64 1 "01"
    , word64 10 "0a"
    , word64 23 "17"
    , word64 24 "1818"
    , word64 25 "1819"
    , word64 100 "1864"
    , word64 255 "18ff"
    , word64 256 "190100"
    , word64 1000 "1903e8"
    , word64 65535 "19ffff"
    , word64 65536 "1a00010000"
    , word64 1000000 "1a000f4240"
    , word64 4294967295 "1affffffff"
    , word64 4294967296 "1b0000000100000000"
    , word64 1000000000000 "1b000000e8d4a51000"
    , word64 9223372036854775808 "1b8000000000000000"
    , word64 18446744073709551615 "1bffffffffffffffff"
    , int64 (-1) "20"
    , int64 (-10) "29"
    , int64 (-24) "37"
    , int64 (-25) "3818"
    , int64 (-100) "3863"
    , int64 (-1000) "3903e7"
    , int64 (-9223372036854775808) "3b7fffffffffffffff"
    , integer (-18446744073709551616) "3bffffffffffffffff"
    , [ encode "double 1.1" "fb3ff199999999999a" (E.encodeDouble 1.1)
      , encode "double 1.0e300" "fb7e37e43c8800759c" (E.encodeDouble 1.0e300)
      , encode "double -4.1" "fbc010666666666666" (E.encodeDouble (-4.1))
      , encode "float 100000.0" "fa47c35000" (E.encodeFloat 100000.0)
      , encode "bytes 01020304" "4401020304" (E.encodeBytes (B.pack [1, 2, 3, 4]))
      , encode "string IETF" "6449455446" (E.encodeString "IETF")
      , encode "array [1,2,3]" "83010203" (E.encodeListLen 3 <> E.encodeWord 1 <> E.encodeWord 2 <> E.encodeWord 3)
      , encode "map {1:2,3:4}" "a201020304" (E.encodeMapLen 2 <> E.encodeWord 1 <> E.encodeWord 2 <> E.encodeWord 3 <> E.encodeWord 4)
      , decode "double 1.1" "fb3ff199999999999a" D.decodeDouble (1.1 :: Double)
      ]
    ]
  where
    word64 :: Word64 -> B.ByteString -> [Check]
    word64 n bytes =
      let name = "word64 " <> T.pack (show n)
       in [encode name bytes (E.encodeWord64 n), decode name bytes D.decodeWord64 n]

    int64 :: Int64 -> B.ByteString -> [Check]
    int64 n bytes =
      let name = "int64 " <> T.pack (show n)
       in [encode name bytes (E.encodeInt64 n)]
            <> [decode name bytes D.decodeInt64 n | n == minBound || n `elem` [-1, -25, -1000]]

    integer :: Integer -> B.ByteString -> [Check]
    integer n bytes =
      let name = "integer " <> T.pack (show n)
       in [encode name bytes (E.encodeInteger n), decode name bytes D.decodeInteger n]

    encode :: Text -> B.ByteString -> E.Encoding -> Check
    encode name expected enc = ("cbor encode " <> name, expected, hex (toStrictByteString enc))

    decode :: (Show a) => Text -> B.ByteString -> (forall s. D.Decoder s a) -> a -> Check
    decode name bytes decoder expected =
      ( "cbor decode " <> name
      , BC.pack (show expected)
      , case deserialiseFromBytes decoder (BL.fromStrict (unhex bytes)) of
          Right (rest, v) | BL.null rest -> BC.pack (show v)
          Right (rest, _) -> "trailing " <> hex (BL.toStrict rest)
          Left err -> BC.pack (show err)
      )

-- | "ok" when a value round-trips and a one-character change is rejected.
getClientSessionR :: Handler Text
getClientSessionR = liftIO $ do
  (_, key) <- CS.randomKey
  sealed <- CS.encryptIO key "payload"
  let flipAt i s = B.take i s <> BC.singleton (if BC.index s i == 'A' then 'B' else 'A') <> B.drop (i + 1) s
      tampered = flipAt (B.length sealed `div` 2) sealed
  pure $
    if CS.decrypt key sealed == Just "payload" && CS.decrypt key tampered == Nothing
      then "ok"
      else T.pack (show (CS.decrypt key sealed, CS.decrypt key tampered))

getRandomR :: Handler Text
getRandomR = liftIO (TE.decodeUtf8 . hex <$> (getRandomBytes 32 :: IO B.ByteString))

hex :: (BA.ByteArrayAccess a) => a -> B.ByteString
hex = BAE.convertToBase BAE.Base16

unhex :: B.ByteString -> B.ByteString
unhex = either error id . BAE.convertFromBase BAE.Base16

foreign export javascript "workerMain" main :: IO ()

main :: IO ()
main = toWaiAppPlain App >>= runCloudflare
