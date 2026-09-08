{-# LANGUAGE FlexibleInstances #-}

-- | The slice of "Data.ByteArray" that `yesod-core` needs.
--
-- See the package description for why the real `memory` is not used here.
--
-- 'constEq' is a genuine reimplementation, not a stub: `yesod-core` relies on
-- it to compare CSRF tokens without leaking their contents through timing, and
-- a naive '==' here would silently reintroduce that vulnerability.
module Data.ByteArray
  ( ByteArrayAccess (..)
  , constEq
  ) where

import           Data.Bits       (xor, (.|.))
import qualified Data.ByteString as B
import           Data.List       (foldl')
import           Data.Word       (Word8)

class ByteArrayAccess a where
  toBytes :: a -> B.ByteString
  length :: a -> Int
  length = B.length . toBytes

instance ByteArrayAccess B.ByteString where
  toBytes = id
  length = B.length

instance ByteArrayAccess [Word8] where
  toBytes = B.pack

-- | Constant-time equality.
--
-- The comparison examines every byte regardless of where the first difference
-- falls, so the running time does not reveal how much of a secret an attacker
-- guessed correctly. Length is compared first and does leak, exactly as in the
-- real implementation — the length of a token is not the secret.
constEq :: (ByteArrayAccess a, ByteArrayAccess b) => a -> b -> Bool
constEq a b =
  B.length xs == B.length ys
    && foldl' (\acc (p, q) -> acc .|. (p `xor` q)) 0 (B.zip xs ys) == 0
  where
    xs = toBytes a
    ys = toBytes b
