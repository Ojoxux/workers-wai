-- |
-- Module      : Crypto.Random.Entropy.WASI
-- License     : BSD-style
-- Stability   : experimental
-- Portability : WASI only
--
-- Entropy from wasi-libc's @getentropy@, i.e. the WASI @random_get@ import.
-- WASI has no @/dev/urandom@ unless the host preopens one, so the Unix
-- backend cannot be relied on.
module Crypto.Random.Entropy.WASI (
    WasiGetEntropy,
) where

import Crypto.Random.Entropy.Source
import Data.Word (Word8)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Ptr

data WasiGetEntropy = WasiGetEntropy

foreign import ccall unsafe "getentropy"
    c_getentropy :: Ptr Word8 -> CSize -> IO CInt

instance EntropySource WasiGetEntropy where
    entropyOpen = return (Just WasiGetEntropy)
    entropyGather _ = go 0
      where
        -- getentropy is limited to 256 bytes per call
        go acc ptr n
            | n <= 0 = return acc
            | otherwise = do
                let chunk = min 256 n
                r <- c_getentropy ptr (fromIntegral chunk)
                if r /= 0
                    then return acc
                    else go (acc + chunk) (ptr `plusPtr` chunk) (n - chunk)
    entropyClose _ = return ()
