{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Run a WAI 'Application' on the Cloudflare Workers runtime.
--
-- Where "Network.Wai.Handler.Warp" owns a socket and speaks HTTP itself, this
-- handler owns nothing: the Workers runtime hands us a JavaScript @Request@ and
-- expects a @Response@ back. All this module does is translate between that
-- pair and WAI's 'Request' \/ 'Response'.
--
-- Usage from an application, which must be linked as a wasm reactor module:
--
-- @
-- foreign export javascript "hs_main" main :: IO ()
--
-- main :: IO ()
-- main = 'runCloudflare' app
-- @
--
-- The JavaScript side calls @hs_main@ once after instantiation to register the
-- application, then calls the @handleRequest@ export for every fetch event.
--
-- This is a proof of concept and implements a deliberately small subset of WAI.
-- See the project README for what is and is not supported.
module Network.Wai.Handler.Cloudflare
  ( runCloudflare
  ) where

import           Control.Exception       (SomeException, displayException, try)
import qualified Data.ByteString          as B
import qualified Data.ByteString.Builder  as BB
import qualified Data.ByteString.Char8    as BC
import qualified Data.ByteString.Internal as BI
import qualified Data.ByteString.Lazy     as BL
import qualified Data.ByteString.Unsafe   as BU
import qualified Data.CaseInsensitive    as CI
import           Data.IORef               (IORef, modifyIORef', newIORef,
                                           readIORef, writeIORef)
import           Data.List               (intercalate)
import qualified Data.Vault.Lazy         as Vault
import           Data.Word               (Word8)
import           Foreign.Ptr             (ptrToWordPtr)
import           GHC.Wasm.Prim
import           Network.HTTP.Types
import           Network.Socket          (SockAddr (..), tupleToHostAddress)
import           Network.Wai
import           Network.Wai.Internal
import           System.IO.Unsafe        (unsafePerformIO)
import           Text.Read               (readMaybe)

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------

-- | The application registered by 'runCloudflare'.
--
-- A reactor module keeps its Haskell heap alive between fetch events, so the
-- application is built once by @hs_main@ and reused. Keeping it here rather
-- than on @globalThis@ means the JavaScript side only ever touches the wasm
-- instance's own exports.
appRef :: IORef (Maybe Application)
appRef = unsafePerformIO (newIORef Nothing)
{-# NOINLINE appRef #-}

-- | Register a WAI 'Application' to serve every subsequent fetch event.
--
-- Unlike 'Network.Wai.Handler.Warp.run' this returns immediately: there is no
-- accept loop to enter, because the Workers runtime drives the handler.
runCloudflare :: Application -> IO ()
runCloudflare = writeIORef appRef . Just

-- | Entry point called by @worker/src/index.mjs@ for each fetch event.
--
-- JSFFI exports are asynchronous by default, so on the JavaScript side this
-- returns a @Promise\<Response\>@, which is exactly what a Workers @fetch@
-- handler may return.
foreign export javascript "handleRequest"
  handleRequest :: JSVal -> IO JSVal

handleRequest :: JSVal -> IO JSVal
handleRequest jsReq = do
  result <- try $ do
    readIORef appRef >>= \case
      Nothing ->
        fail "no Application registered - did hs_main run and call runCloudflare?"
      Just app -> do
        req <- fromWorkerRequest jsReq
        -- WAI's continuation-passing shape cannot be observed from JavaScript,
        -- so capture the response the application hands to `respond`.
        slot <- newIORef Nothing
        _ <- app req $ \res -> do
          writeIORef slot (Just res)
          pure ResponseReceived
        readIORef slot >>= \case
          Nothing  -> fail "the Application never called respond"
          Just res -> toWorkerResponse res
  case result of
    Right jsRes -> pure jsRes
    Left err    -> serverError err

-- ---------------------------------------------------------------------------
-- Cloudflare Request -> WAI Request
-- ---------------------------------------------------------------------------

fromWorkerRequest :: JSVal -> IO Request
fromWorkerRequest jsReq = do
  method <- toByteString <$> js_reqMethod jsReq
  path <- toByteString <$> js_reqPath jsReq
  query <- toByteString <$> js_reqQuery jsReq
  secure <- js_reqIsSecure jsReq
  headers <- decodeHeaders . fromJSString <$> js_reqHeaders jsReq
  body <- readRequestBody jsReq
  reader <- chunkReader body
  pure
    Request
      { requestMethod = method
      , httpVersion = http11
        -- ^ Workers does not expose the client's HTTP version.
      , rawPathInfo = path
      , rawQueryString = query
      , requestHeaders = headers
      , isSecure = secure
      , remoteHost = remoteHostFrom headers
      , pathInfo = decodePathSegments path
      , queryString = parseQuery query
      , requestBody = reader
      , vault = Vault.empty
      , requestBodyLength = KnownLength (fromIntegral (B.length body))
      , requestHeaderHost = lookup hHost headers
      , requestHeaderRange = lookup hRange headers
      , requestHeaderReferer = lookup hReferer headers
      , requestHeaderUserAgent = lookup hUserAgent headers
      }

-- | Read the whole request body into memory.
--
-- The body is consumed eagerly rather than streamed: @Request.arrayBuffer()@
-- resolves once the client has finished sending. That is the honest limit of
-- this handler -- see the README. Bodies large enough to matter would need the
-- @ReadableStream@ reader instead.
readRequestBody :: JSVal -> IO B.ByteString
readRequestBody jsReq = do
  arr <- js_reqBody jsReq
  len <- js_byteLength arr
  body <-
    if len == 0
      then pure B.empty
      else BI.create len $ \ptr ->
        js_writeBytes arr (fromIntegral (ptrToWordPtr ptr)) len
  freeJSVal arr
  pure body

-- | WAI's 'requestBody' hands back successive chunks and then empty strings
-- forever. The body is already in memory, so it is delivered as one chunk.
chunkReader :: B.ByteString -> IO (IO B.ByteString)
chunkReader body = do
  remaining <- newIORef body
  pure $ do
    chunk <- readIORef remaining
    writeIORef remaining B.empty
    pure chunk

-- | WAI insists on a 'SockAddr', which Workers has no direct equivalent for.
-- Recover the client address from @CF-Connecting-IP@ when it parses as IPv4,
-- and fall back to a placeholder otherwise. The port is always 0.
remoteHostFrom :: RequestHeaders -> SockAddr
remoteHostFrom headers =
  case lookup "cf-connecting-ip" headers >>= parseIPv4 of
    Just addr -> SockAddrInet 0 addr
    Nothing   -> SockAddrInet 0 0
  where
    parseIPv4 raw = case traverse octet (BC.split '.' raw) of
      Just [a, b, c, d] -> Just (tupleToHostAddress (a, b, c, d))
      _                 -> Nothing
    octet :: B.ByteString -> Maybe Word8
    octet bs = do
      n <- readMaybe (BC.unpack bs) :: Maybe Int
      if n >= 0 && n <= 255 then Just (fromIntegral n) else Nothing

-- ---------------------------------------------------------------------------
-- WAI Response -> Cloudflare Response
-- ---------------------------------------------------------------------------

toWorkerResponse :: Response -> IO JSVal
toWorkerResponse = \case
  ResponseBuilder status headers builder ->
    buildResponse status headers (BB.toLazyByteString builder)
  ResponseStream status headers withBody -> do
    -- Buffered, not streamed: the whole body is accumulated before the
    -- Response is constructed, so the client sees no output until the
    -- StreamingBody finishes. Enough for Yesod's respondSource; not enough
    -- for server-sent events or a long-lived download.
    acc <- newIORef mempty
    withBody (\chunk -> modifyIORef' acc (<> chunk)) (pure ())
    builder <- readIORef acc
    buildResponse status headers (BB.toLazyByteString builder)
  ResponseFile{} -> unsupported "responseFile"
  ResponseRaw{}  -> unsupported "responseRaw"

buildResponse :: Status -> ResponseHeaders -> BL.ByteString -> IO JSVal
buildResponse status headers body = do
  jsHeaders <- js_mkHeaders (toJSString (encodeHeaders headers))
  let code = statusCode status
  if hasNullBody code
    then js_mkEmptyResponse code jsHeaders
    else do
      jsBody <- toJSUint8Array (BL.toStrict body)
      js_mkResponse jsBody code jsHeaders

-- | @new Response(body, ...)@ throws for these statuses unless the body is
-- @null@, so they get the no-body constructor.
hasNullBody :: Int -> Bool
hasNullBody code = code `elem` [101, 204, 205, 304]

-- | Copy a strict 'B.ByteString' into a fresh @Uint8Array@.
--
-- The pointer is only valid for the duration of a synchronous ('unsafe') JSFFI
-- call, during which no GC can run, and the JavaScript side copies out of wasm
-- linear memory before returning.
toJSUint8Array :: B.ByteString -> IO JSVal
toJSUint8Array bs =
  BU.unsafeUseAsCStringLen bs $ \(ptr, len) ->
    js_copyBytes (fromIntegral (ptrToWordPtr ptr)) len

-- ---------------------------------------------------------------------------
-- Errors
-- ---------------------------------------------------------------------------

serverError :: SomeException -> IO JSVal
serverError err = do
  let msg = "wai-handler-cloudflare: unhandled exception\n" <> displayException err
  js_consoleError (toJSString msg)
  plainText status500 msg

unsupported :: String -> IO JSVal
unsupported feature =
  plainText status501 $
    "wai-handler-cloudflare: " <> feature <> " is not supported by this PoC handler\n"

plainText :: Status -> String -> IO JSVal
plainText status msg =
  buildResponse
    status
    [(hContentType, "text/plain; charset=utf-8")]
    (BL.fromStrict (BC.pack msg))

-- ---------------------------------------------------------------------------
-- Header encoding
-- ---------------------------------------------------------------------------
--
-- Headers cross the FFI boundary as a single NUL-separated string of
-- alternating names and values. A NUL can never occur in an HTTP header, and
-- this avoids pulling a JSON library into the handler.
--
-- Bytes are mapped to characters one-to-one (latin-1), so non-ASCII header
-- values are not round-tripped faithfully. Header values are ASCII in practice.

encodeHeaders :: ResponseHeaders -> String
encodeHeaders =
  intercalate "\NUL"
    . concatMap (\(name, value) -> [BC.unpack (CI.original name), BC.unpack value])

decodeHeaders :: String -> RequestHeaders
decodeHeaders "" = []
decodeHeaders raw = pairs (splitOn '\NUL' raw)
  where
    pairs (name : value : rest) = (CI.mk (BC.pack name), BC.pack value) : pairs rest
    pairs _                     = []

splitOn :: Char -> String -> [String]
splitOn sep s = case break (== sep) s of
  (chunk, [])       -> [chunk]
  (chunk, _ : rest) -> chunk : splitOn sep rest

toByteString :: JSString -> B.ByteString
toByteString = BC.pack . fromJSString

-- ---------------------------------------------------------------------------
-- JSFFI
-- ---------------------------------------------------------------------------
--
-- Every snippet below is a single JavaScript expression. `unsafe` means the
-- call is synchronous and cannot trigger a GC, which is what makes the raw
-- memory access in js_copyBytes sound.

foreign import javascript unsafe "$1.method"
  js_reqMethod :: JSVal -> IO JSString

foreign import javascript unsafe "new URL($1.url).pathname"
  js_reqPath :: JSVal -> IO JSString

foreign import javascript unsafe "new URL($1.url).search"
  js_reqQuery :: JSVal -> IO JSString

foreign import javascript unsafe "new URL($1.url).protocol === 'https:'"
  js_reqIsSecure :: JSVal -> IO Bool

foreign import javascript unsafe "[...$1.headers].flat().join('\\u0000')"
  js_reqHeaders :: JSVal -> IO JSString

-- | Asynchronous ('safe'): awaits the body, suspending only this Haskell
-- thread. Returns an empty Uint8Array for bodyless requests such as GET.
foreign import javascript safe "const b = await $1.arrayBuffer(); return new Uint8Array(b);"
  js_reqBody :: JSVal -> IO JSVal

foreign import javascript unsafe "$1.length"
  js_byteLength :: JSVal -> IO Int

-- | Copy a Uint8Array into @[ptr, ptr + len)@ of wasm linear memory.
foreign import javascript unsafe "new Uint8Array(__exports.memory.buffer, $2, $3).set($1)"
  js_writeBytes :: JSVal -> Int -> Int -> IO ()

-- | Copy @[ptr, ptr + len)@ out of wasm linear memory. The outer constructor
-- copies, so the result stays valid after the Haskell buffer is collected.
foreign import javascript unsafe "new Uint8Array(new Uint8Array(__exports.memory.buffer, $1, $2))"
  js_copyBytes :: Int -> Int -> IO JSVal

foreign import javascript unsafe "$1 === '' ? [] : $1.split('\\u0000').flatMap((x, i, a) => i % 2 ? [] : [[x, a[i + 1]]])"
  js_mkHeaders :: JSString -> IO JSVal

foreign import javascript unsafe "new Response($1, { status: $2, headers: $3 })"
  js_mkResponse :: JSVal -> Int -> JSVal -> IO JSVal

foreign import javascript unsafe "new Response(null, { status: $1, headers: $2 })"
  js_mkEmptyResponse :: Int -> JSVal -> IO JSVal

foreign import javascript unsafe "console.error($1)"
  js_consoleError :: JSString -> IO ()
