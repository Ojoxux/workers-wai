{-# LANGUAGE ForeignFunctionInterface #-}

-- | Cryptographically secure randomness on @wasm32-wasi@, via the host.
--
-- The real `entropy` package cannot be built here — see the package
-- description — but the functionality is genuinely available: the Workers
-- runtime (like every browser) exposes @crypto.getRandomValues@, which is a
-- CSPRNG. This module calls it through JSFFI.
--
-- So unlike the other shims in this project, this one is a real implementation
-- rather than a stand-in.
module System.Entropy
  ( getEntropy
  , getHardwareEntropy
  , CryptHandle
  , openHandle
  , closeHandle
  , hGetEntropy
  ) where

import qualified Data.ByteString          as B
import qualified Data.ByteString.Internal as BI
import           Foreign.Ptr              (ptrToWordPtr)

-- | Fill @[ptr, ptr + len)@ with random bytes.
--
-- @crypto.getRandomValues@ rejects requests over 65536 bytes, so the range is
-- filled in chunks. Synchronous, so no GC can move the buffer during the call.
foreign import javascript unsafe
  "(() => { const m = new Uint8Array(__exports.memory.buffer, $1, $2); for (let i = 0; i < m.length; i += 65536) { crypto.getRandomValues(m.subarray(i, Math.min(i + 65536, m.length))); } })()"
  js_randomBytes :: Int -> Int -> IO ()

-- | Get n bytes of cryptographically secure randomness.
getEntropy :: Int -> IO B.ByteString
getEntropy n
  | n <= 0 = pure B.empty
  | otherwise = BI.create n $ \ptr ->
      js_randomBytes (fromIntegral (ptrToWordPtr ptr)) n

-- | There is no RDRAND-style instruction to reach from wasm.
getHardwareEntropy :: Int -> IO (Maybe B.ByteString)
getHardwareEntropy _ = pure Nothing

-- | A handle exists only to match the real API; there is no device to open.
data CryptHandle = CryptHandle

openHandle :: IO CryptHandle
openHandle = pure CryptHandle

closeHandle :: CryptHandle -> IO ()
closeHandle _ = pure ()

hGetEntropy :: CryptHandle -> Int -> IO B.ByteString
hGetEntropy _ = getEntropy
