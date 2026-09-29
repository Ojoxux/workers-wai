{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Run a WAI 'Application' on the Cloudflare Workers runtime.
--
-- A thin adapter over "Cloudflare.Workers.Entry": each incoming
-- 'F.Request' becomes a WAI 'Request', and the WAI 'Response' becomes an
-- 'F.Response'. The application module exports its @main@ once:
--
-- @
-- foreign export javascript "workerMain" main :: IO ()
--
-- main :: IO ()
-- main = 'runCloudflareWith' $ \\env -> do
--   key <- Env.var env \"SESSION_KEY\"
--   toWaiAppPlain (App key)
-- @
--
-- See docs/wai-support.md for the supported subset of WAI.
module Network.Wai.Handler.Cloudflare
  ( runCloudflare
  , runCloudflareWith
  , contextKey
  , requestContext
  ) where

import           Cloudflare.Workers.Context (Context)
import           Cloudflare.Workers.Entry   (runWorker)
import           Cloudflare.Workers.Env     (Env)
import qualified Cloudflare.Workers.Fetch   as F
import qualified Data.ByteString            as B
import qualified Data.ByteString.Builder    as BB
import qualified Data.ByteString.Char8      as BC
import qualified Data.ByteString.Lazy       as BL
import           Data.IORef                 (modifyIORef', newIORef, readIORef,
                                             writeIORef)
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import qualified Data.Text.Encoding         as TE
import qualified Data.Vault.Lazy            as Vault
import           Data.Word                  (Word8)
import           Network.HTTP.Types
import           Network.Socket             (SockAddr (..), tupleToHostAddress)
import           Network.Wai
import           Network.Wai.Internal
import           System.IO.Unsafe           (unsafePerformIO)
import           Text.Read                  (readMaybe)

-- | Serve a fixed 'Application'.
runCloudflare :: Application -> IO ()
runCloudflare app = runCloudflareWith (\_ -> pure app)

-- | Build the 'Application' from the Worker's env, once per isolate.
runCloudflareWith :: (Env -> IO Application) -> IO ()
runCloudflareWith mk = runWorker $ \env -> serve <$> mk env

-- | Where the request's 'Context' is stored in the WAI 'vault'.
contextKey :: Vault.Key Context
contextKey = unsafePerformIO Vault.newKey
{-# NOINLINE contextKey #-}

requestContext :: Request -> Maybe Context
requestContext = Vault.lookup contextKey . vault

serve :: Application -> F.Request -> Context -> IO F.Response
serve app freq ctx = do
  req <- toWaiRequest freq ctx
  -- WAI's continuation cannot be observed from JavaScript, so capture the
  -- response the application hands to `respond`.
  slot <- newIORef Nothing
  _ <- app req $ \res -> do
    writeIORef slot (Just res)
    pure ResponseReceived
  readIORef slot >>= \case
    Nothing  -> fail "the Application never called respond"
    Just res -> fromWaiResponse res

-- ---------------------------------------------------------------------------
-- F.Request -> WAI Request
-- ---------------------------------------------------------------------------

toWaiRequest :: F.Request -> Context -> IO Request
toWaiRequest freq ctx = do
  let (secure, path, query) = splitUrl (F.url freq)
      hs = F.headers freq
  -- Read in full: the Application sees the body as a single chunk.
  body <- F.bytes (F.body freq)
  reader <- chunkReader body
  pure
    Request
      { requestMethod = F.method freq
      , httpVersion = http11
        -- ^ Workers does not expose the client's HTTP version.
      , rawPathInfo = path
      , rawQueryString = query
      , requestHeaders = hs
      , isSecure = secure
      , remoteHost = remoteHostFrom hs
      , pathInfo = decodePathSegments path
      , queryString = parseQuery query
      , requestBody = reader
      , vault = Vault.insert contextKey ctx Vault.empty
      , requestBodyLength = KnownLength (fromIntegral (B.length body))
      , requestHeaderHost = lookup hHost hs
      , requestHeaderRange = lookup hRange hs
      , requestHeaderReferer = lookup hReferer hs
      , requestHeaderUserAgent = lookup hUserAgent hs
      }

-- | Scheme check, path and query (with its leading @?@, or empty) of the
-- absolute, already percent-encoded URL the runtime hands us. The fragment,
-- if any, is dropped first: @request.url@ can carry one for service-binding,
-- self-fetch and test requests, and it is never sent to a server.
splitUrl :: Text -> (Bool, B.ByteString, B.ByteString)
splitUrl u =
  let withoutFragment = T.takeWhile (/= '#') u
      (scheme, rest) = T.breakOn "://" withoutFragment
      afterAuthority = T.dropWhile (/= '/') (T.drop 3 rest)
      (p, q) = T.breakOn "?" afterAuthority
      path = if T.null p then "/" else p
      query = if q == "?" then "" else q
   in (scheme == "https", TE.encodeUtf8 path, TE.encodeUtf8 query)

-- | WAI's 'requestBody' hands back successive chunks and then empty strings.
chunkReader :: B.ByteString -> IO (IO B.ByteString)
chunkReader body = do
  remaining <- newIORef body
  pure $ do
    chunk <- readIORef remaining
    writeIORef remaining B.empty
    pure chunk

-- | WAI insists on a 'SockAddr'. Recover the client address from
-- @CF-Connecting-IP@ when it parses as IPv4; otherwise a placeholder.
remoteHostFrom :: RequestHeaders -> SockAddr
remoteHostFrom hs =
  case lookup "cf-connecting-ip" hs >>= parseIPv4 of
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
-- WAI Response -> F.Response
-- ---------------------------------------------------------------------------

fromWaiResponse :: Response -> IO F.Response
fromWaiResponse = \case
  ResponseBuilder st hs builder ->
    pure (bytesResponse st hs (BB.toLazyByteString builder))
  ResponseStream st hs withBody -> do
    -- Buffered, not streamed: the client sees nothing until the
    -- StreamingBody finishes. See docs/wai-support.md.
    acc <- newIORef mempty
    withBody (\chunk -> modifyIORef' acc (<> chunk)) (pure ())
    builder <- readIORef acc
    pure (bytesResponse st hs (BB.toLazyByteString builder))
  ResponseFile{} -> pure (unsupported "responseFile")
  ResponseRaw{} -> pure (unsupported "responseRaw")

bytesResponse :: Status -> ResponseHeaders -> BL.ByteString -> F.Response
bytesResponse st hs b = F.response (statusCode st) hs (F.bodyBytes (BL.toStrict b))

unsupported :: Text -> F.Response
unsupported feature =
  F.response
    501
    [(hContentType, "text/plain; charset=utf-8")]
    (F.bodyText ("wai-handler-cloudflare: " <> feature <> " is not supported\n"))
