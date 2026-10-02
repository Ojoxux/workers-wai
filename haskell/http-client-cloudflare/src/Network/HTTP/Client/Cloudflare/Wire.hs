{-# LANGUAGE OverloadedStrings #-}

-- | HTTP/1.1 on the wire, the two directions the bridge needs: parsing the
-- request http-client wrote, and rendering a fetch response for http-client
-- to read. Pure; no JavaScript.
--
-- Lengths are compared as 'Integer' before any conversion to 'Int', because
-- 'Int' is 32-bit on wasm32.
module Network.HTTP.Client.Cloudflare.Wire
  ( WireRequest (..)
  , parseRequest
  , renderResponse
  , encodeTarget
  , maxHeaderBytes
  , maxBodyBytes
  ) where

import qualified Data.ByteString         as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Char8   as BC
import qualified Data.ByteString.Lazy    as BL
import qualified Data.CaseInsensitive    as CI
import           Data.Bits               (shiftR, (.&.))
import           Data.Char               (digitToInt, isHexDigit)
import           Data.Word               (Word8)
import           Network.HTTP.Types      (Header, HeaderName)

data WireRequest = WireRequest
  { wrMethod  :: B.ByteString
  , wrTarget  :: B.ByteString
    -- ^ Origin-form path and query, e.g. @/a/b?c=d@.
  , wrHeaders :: [Header]
  , wrBody    :: B.ByteString
  }
  deriving (Show)

maxHeaderBytes :: Int
maxHeaderBytes = 64 * 1024

maxBodyBytes :: Integer
maxBodyBytes = 32 * 1024 * 1024

-- | The complete request, or why it is not one.
parseRequest :: B.ByteString -> Either String WireRequest
parseRequest raw = do
  let (headBlock, rest) = B.breakSubstring "\r\n\r\n" raw
  if B.null rest
    then
      if B.length raw > maxHeaderBytes
        then Left "request headers exceed 64 KiB"
        else Left "request is incomplete (no end of headers)"
    else pure ()
  if B.length headBlock > maxHeaderBytes then Left "request headers exceed 64 KiB" else pure ()
  let afterHead = B.drop 4 rest
  (requestLine, headerLines) <- case splitLines headBlock of
    l : ls -> Right (l, ls)
    [] -> Left "empty request"
  -- Method up to the first space, version after the last; everything in
  -- between is the target, so a target containing spaces survives intact.
  let (m, afterMethod) = BC.break (== ' ') requestLine
      (beforeVersion, v) = BC.breakEnd (== ' ') afterMethod
      target = B.drop 1 (B.dropEnd 1 beforeVersion)
  if B.null m || B.null target || v `notElem` ["HTTP/1.1", "HTTP/1.0"]
    then Left ("malformed request line: " <> BC.unpack requestLine)
    else pure ()
  if BC.head target /= '/'
    then Left "request target is not origin-form; http-client-cloudflare does not support proxies"
    else pure ()
  headers <- traverse parseHeader headerLines
  -- The same test http-client applies: only this exact value makes it wait
  -- for a 100 before sending the body. Any other value is not an error
  -- (the header itself is never forwarded to fetch).
  if lookup "expect" (lower headers) == Just "100-continue"
    then Left "Expect: 100-continue is not supported (fetch sends the whole request at once)"
    else pure ()
  body <- case lookup "transfer-encoding" (lower headers) of
    Just te | "chunked" `B.isInfixOf` te -> dechunk afterHead
    _ -> case lookup "content-length" (lower headers) of
      Just cl -> do
        n <- maybe (Left ("bad Content-Length: " <> BC.unpack cl)) Right (decimal cl)
        if n > maxBodyBytes then Left "request body exceeds 32 MiB" else pure ()
        if n > toInteger (B.length afterHead) then Left "request body is incomplete" else pure ()
        pure (B.take (fromInteger n) afterHead)
      Nothing -> pure B.empty
  pure WireRequest {wrMethod = m, wrTarget = target, wrHeaders = headers, wrBody = body}
  where
    lower = map (\(k, v) -> (CI.foldedCase k, v))

splitLines :: B.ByteString -> [B.ByteString]
splitLines bs
  | B.null bs = []
  | otherwise =
      let (line, rest) = B.breakSubstring "\r\n" bs
       in line : if B.null rest then [] else splitLines (B.drop 2 rest)

parseHeader :: B.ByteString -> Either String Header
parseHeader line =
  case BC.break (== ':') line of
    (name, rest) | not (B.null name), not (B.null rest) -> Right (CI.mk name, trim (B.drop 1 rest))
    _ -> Left ("malformed header line: " <> BC.unpack line)
  where
    trim = BC.dropWhile (== ' ') . BC.dropWhileEnd (== ' ')

decimal :: B.ByteString -> Maybe Integer
decimal s
  | B.null s || not (BC.all (`elem` ['0' .. '9']) s) = Nothing
  | otherwise = Just (BC.foldl' (\acc c -> acc * 10 + toInteger (digitToInt c)) 0 s)

hexadecimal :: B.ByteString -> Maybe Integer
hexadecimal s
  | B.null s || not (BC.all isHexDigit s) = Nothing
  | otherwise = Just (BC.foldl' (\acc c -> acc * 16 + toInteger (digitToInt c)) 0 s)

-- | Decode a chunked body: size line (hex, optional extensions), data, CRLF,
-- repeated until a zero-size chunk; trailers are skipped.
dechunk :: B.ByteString -> Either String B.ByteString
dechunk = go mempty 0
  where
    go acc total bs = do
      let (sizeLine, rest) = B.breakSubstring "\r\n" bs
      if B.null rest then Left "chunked body is incomplete" else pure ()
      size <- maybe (Left ("bad chunk size: " <> BC.unpack sizeLine)) Right (hexadecimal (BC.takeWhile (/= ';') sizeLine))
      let afterSize = B.drop 2 rest
      if size == 0
        then pure (BL.toStrict (BB.toLazyByteString acc))
        else do
          if total + size > maxBodyBytes then Left "request body exceeds 32 MiB" else pure ()
          if size + 2 > toInteger (B.length afterSize) then Left "chunked body is incomplete" else pure ()
          let (chunk, afterChunk) = B.splitAt (fromInteger size) afterSize
          if B.take 2 afterChunk /= "\r\n" then Left "chunk not followed by CRLF" else pure ()
          go (acc <> BB.byteString chunk) (total + size) (B.drop 2 afterChunk)

-- | A request target as URL text for fetch: bytes that cannot appear
-- literally in a URL (controls, space, and anything >= 0x80) are
-- percent-encoded byte by byte, as are @#@ and @\\@, which the URL parser
-- would otherwise take as the start of a fragment and as a path separator.
-- Existing escapes are left alone.
--
-- The result is still parsed as a URL, so @.@ and @..@ path segments are
-- normalised away before the request is sent (@/a/../b@ arrives as @/b@).
encodeTarget :: B.ByteString -> B.ByteString
encodeTarget = BL.toStrict . BB.toLazyByteString . B.foldr (\w acc -> enc w <> acc) mempty
  where
    enc :: Word8 -> BB.Builder
    enc w
      | w >= 0x80 || w < 0x21 || w == 0x23 || w == 0x5c =
          BB.char7 '%' <> hex (w `shiftR` 4) <> hex (w .&. 0x0f)
      | otherwise = BB.word8 w
    hex n = BB.word8 (B.index "0123456789ABCDEF" (fromIntegral n))

-- | HTTP/1.1 response bytes for http-client, given the request method. The
-- body is complete, so its length is exact and replaces any upstream
-- framing. A response that carries no body (to @HEAD@, or a 1xx, 204 or 304)
-- keeps the upstream Content-Length, which describes the representation
-- rather than this empty body, and gets none if upstream sent none.
-- Content-Encoding is dropped: fetch has already decoded the body, and
-- http-client would decode it again. The connection is closed after this
-- response.
renderResponse :: B.ByteString -> Int -> B.ByteString -> [Header] -> B.ByteString -> B.ByteString
renderResponse method status reason headers body =
  BL.toStrict . BB.toLazyByteString $
    "HTTP/1.1 " <> BB.intDec status <> " " <> BB.byteString reason <> "\r\n"
      <> foldMap header (filter (not . dropped . fst) headers)
      <> (if bodiless then mempty else "Content-Length: " <> BB.intDec (B.length body) <> "\r\n")
      <> "Connection: close\r\n\r\n"
      <> BB.byteString body
  where
    bodiless = method == "HEAD" || (status >= 100 && status < 200) || status `elem` [204, 304]
    header (k, v) = BB.byteString (CI.original k) <> ": " <> BB.byteString v <> "\r\n"
    dropped :: HeaderName -> Bool
    dropped k =
      CI.foldedCase k `elem` ["transfer-encoding", "connection", "content-encoding"]
        || (CI.foldedCase k == "content-length" && not bodiless)
