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
  , maxHeaderBytes
  , maxBodyBytes
  ) where

import qualified Data.ByteString         as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Char8   as BC
import qualified Data.ByteString.Lazy    as BL
import qualified Data.CaseInsensitive    as CI
import           Data.Char               (digitToInt, isHexDigit)
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
  (m, target) <- case BC.split ' ' requestLine of
    [m, t, v] | v `elem` ["HTTP/1.1", "HTTP/1.0"] -> Right (m, t)
    _ -> Left ("malformed request line: " <> BC.unpack requestLine)
  headers <- traverse parseHeader headerLines
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

-- | HTTP/1.1 response bytes for http-client: the body is complete, so the
-- length is exact; framing headers from the original response are replaced
-- and the connection is closed after this response.
renderResponse :: Int -> B.ByteString -> [Header] -> B.ByteString -> B.ByteString
renderResponse status reason headers body =
  BL.toStrict . BB.toLazyByteString $
    "HTTP/1.1 " <> BB.intDec status <> " " <> BB.byteString reason <> "\r\n"
      <> foldMap header (filter (not . dropped . fst) headers)
      <> "Content-Length: " <> BB.intDec (B.length body) <> "\r\n"
      <> "Connection: close\r\n\r\n"
      <> BB.byteString body
  where
    header (k, v) = BB.byteString (CI.original k) <> ": " <> BB.byteString v <> "\r\n"
    dropped :: HeaderName -> Bool
    dropped k = CI.foldedCase k `elem` ["content-length", "transfer-encoding", "connection"]
