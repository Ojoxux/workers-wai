{-# LANGUAGE OverloadedStrings #-}

-- | The small part of WebCrypto that sessions need: random bytes, an
-- HKDF-derived AES-256-GCM key, and authenticated encryption with it.
--
-- Every @crypto.subtle@ operation returns a Promise, so those imports are
-- @safe@ and forced with 'awaitJS'. Keys never leave WebCrypto: 'AesGcmKey'
-- holds a non-extractable @CryptoKey@.
module Cloudflare.Workers.Crypto
  ( randomBytes
  , AesGcmKey
  , hkdfAesGcmKey
  , aesGcmEncrypt
  , aesGcmDecrypt
  ) where

import           Control.Exception               (throwIO, try)
import qualified Data.ByteString                 as B
import qualified Data.ByteString.Internal        as BI
import           Foreign.Ptr                     (plusPtr, ptrToWordPtr)

import           Cloudflare.Workers.Internal.FFI

-- | A non-extractable AES-256-GCM @CryptoKey@.
newtype AesGcmKey = AesGcmKey JSVal

-- | Cryptographically secure random bytes from @crypto.getRandomValues@.
-- Requests above its 65,536-byte limit are filled in chunks.
randomBytes :: Int -> IO B.ByteString
randomBytes n
  | n < 0 = error ("Cloudflare.Workers.Crypto.randomBytes: negative length " <> show n)
  | n == 0 = pure B.empty
  | otherwise = BI.create n $ \ptr ->
      let fill off
            | off >= n = pure ()
            | otherwise = do
                let len = min 65536 (n - off)
                js_fillRandom (fromIntegral (ptrToWordPtr (ptr `plusPtr` off))) len
                fill (off + len)
       in fill 0

-- | HKDF-SHA256 from input keying material, salt and info.
hkdfAesGcmKey :: B.ByteString -> B.ByteString -> B.ByteString -> IO AesGcmKey
hkdfAesGcmKey ikm salt info = do
  ikm' <- toJSBytes ikm
  salt' <- toJSBytes salt
  info' <- toJSBytes info
  AesGcmKey <$> awaitJS (js_hkdfAesGcmKey ikm' salt' info')

-- | Ciphertext followed by the 16-byte authentication tag.
aesGcmEncrypt :: AesGcmKey -> B.ByteString -> B.ByteString -> B.ByteString -> IO B.ByteString
aesGcmEncrypt (AesGcmKey key) iv aad plaintext = do
  iv' <- toJSBytes iv
  aad' <- toJSBytes aad
  pt' <- toJSBytes plaintext
  awaitJS (js_encrypt key iv' aad' pt') >>= fromJSBytes

-- | 'Nothing' when authentication fails (wrong key, wrong AAD, tampered
-- data): WebCrypto reports that, and only that, as @OperationError@. Any
-- other failure is a caller error and is thrown as 'JSError'.
aesGcmDecrypt :: AesGcmKey -> B.ByteString -> B.ByteString -> B.ByteString -> IO (Maybe B.ByteString)
aesGcmDecrypt (AesGcmKey key) iv aad ciphertext = do
  iv' <- toJSBytes iv
  aad' <- toJSBytes aad
  ct' <- toJSBytes ciphertext
  result <- try (awaitJS (js_decrypt key iv' aad' ct'))
  case result of
    Right v -> Just <$> fromJSBytes v
    Left err
      | jsErrorName err == "OperationError" -> pure Nothing
      | otherwise -> throwIO err

-- | unsafe: getRandomValues only throws above 65,536 bytes, and
-- 'randomBytes' never asks for more. Writes straight into wasm memory,
-- which no GC can move during a synchronous import.
foreign import javascript unsafe "crypto.getRandomValues(new Uint8Array(__exports.memory.buffer, $1, $2))"
  js_fillRandom :: Int -> Int -> IO ()

foreign import javascript safe
  "const base = await crypto.subtle.importKey('raw', $1, 'HKDF', false, ['deriveKey']); \
  \return await crypto.subtle.deriveKey({ name: 'HKDF', hash: 'SHA-256', salt: $2, info: $3 }, \
  \base, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);"
  js_hkdfAesGcmKey :: JSVal -> JSVal -> JSVal -> IO JSVal

foreign import javascript safe
  "return new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: $2, additionalData: $3 }, $1, $4));"
  js_encrypt :: JSVal -> JSVal -> JSVal -> JSVal -> IO JSVal

foreign import javascript safe
  "return new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: $2, additionalData: $3 }, $1, $4));"
  js_decrypt :: JSVal -> JSVal -> JSVal -> JSVal -> IO JSVal
