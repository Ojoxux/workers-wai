-- | The session plaintext, before encryption:
--
-- @
-- expiry (Unix seconds, Word64 BE)
-- ‖ entry count (Word32 BE)
-- ‖ ( key length (Word32 BE) ‖ key (UTF-8) ‖ value length (Word32 BE) ‖ value ) × count
-- @
--
-- The module is public so the format is documented and testable, but it is not
-- a stable API.
--
-- Decoding is total: malformed input gives 'Nothing', never an exception.
-- Lengths and the entry count are compared as 'Integer', never narrowed to
-- 'Int' first: on wasm32 'Int' is 32 bits, and a length of 2^31 or more
-- would wrap to a negative number and pass a bounds check.
module Yesod.Cloudflare.Session.Codec
  ( encodePayload
  , decodePayload
  ) where

import           Control.Monad           (guard)
import           Data.Bits               (shiftL, (.|.))
import qualified Data.ByteString         as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy    as BL
import qualified Data.List               as List
import qualified Data.Map.Strict         as Map
import           Data.Text               (Text)
import qualified Data.Text.Encoding      as TE
import           Data.Word               (Word32, Word64)

encodePayload :: Word64 -> Map.Map Text B.ByteString -> B.ByteString
encodePayload expires entries =
  BL.toStrict . BB.toLazyByteString $
    BB.word64BE expires
      <> BB.word32BE (fromIntegral (Map.size entries))
      <> foldMap entry (Map.toAscList entries)
  where
    entry (k, v) =
      let kb = TE.encodeUtf8 k
       in field kb <> field v
    field b = BB.word32BE (fromIntegral (B.length b)) <> BB.byteString b

decodePayload :: B.ByteString -> Maybe (Word64, Map.Map Text B.ByteString)
decodePayload input = do
  (expires, afterExpiry) <- word 8 input
  (count, afterCount) <- word 4 afterExpiry
  -- Each entry takes at least 8 bytes (two lengths), so a count the rest of
  -- the input cannot hold is rejected up front.
  guard (toInteger (count :: Word32) * 8 <= toInteger (B.length afterCount))
  (entries, rest) <- go count afterCount []
  guard (B.null rest)
  pure (expires, Map.fromList entries)
  where
    go 0 bs acc = Just (reverse acc, bs)
    go n bs acc = do
      (kb, afterKey) <- field bs
      key <- either (const Nothing) Just (TE.decodeUtf8' kb)
      (value, afterValue) <- field afterKey
      go (n - 1) afterValue ((key, value) : acc)
    field bs = do
      (len, afterLen) <- word 4 bs
      guard (toInteger (len :: Word32) <= toInteger (B.length afterLen))
      pure (B.splitAt (fromIntegral len) afterLen)

-- | A big-endian unsigned integer of the given byte width.
word :: (Integral a, Num a) => Int -> B.ByteString -> Maybe (a, B.ByteString)
word width bs = do
  guard (B.length bs >= width)
  let (bytes, rest) = B.splitAt width bs
  pure (fromIntegral (List.foldl' (\acc b -> (acc `shiftL` 8) .|. toInteger b) 0 (B.unpack bytes)), rest)
