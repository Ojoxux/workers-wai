{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | An http-client 'Manager' for Cloudflare Workers.
--
-- Workers has no sockets, so the usual managers cannot connect. This one
-- replaces the connection: it buffers the HTTP/1.1 request http-client
-- writes, sends it with the Workers @fetch@ API on the first read, and hands
-- the response back as HTTP/1.1 bytes. TLS is fetch's job, so no @tls@
-- package or certificate store is involved.
--
-- @
-- manager <- newFetchManager
-- res <- httpLbs request manager
-- @
--
-- Redirects are not followed by fetch: http-client follows them itself, with
-- its own redirect count and cookie handling. A response body is decoded by
-- fetch, so Content-Encoding is removed before http-client sees it.
--
-- A failed fetch (no response at all) surfaces as
-- @HttpExceptionRequest _ (ConnectionFailure _)@. A request the bridge
-- cannot send (malformed, too large, proxied, or using
-- @Expect: 100-continue@) surfaces as
-- @HttpExceptionRequest _ (InternalException _)@ with the reason in the
-- message.
module Network.HTTP.Client.Cloudflare
  ( newFetchManager
  , fetchManagerSettings
  ) where

import qualified Cloudflare.Workers.Fetch             as F
import           Control.Exception                    (Handler (..), IOException,
                                                       catches, throwIO, toException)
import qualified Data.ByteString                      as B
import qualified Data.ByteString.Builder              as BB
import qualified Data.ByteString.Char8                as BC
import qualified Data.ByteString.Lazy                 as BL
import qualified Data.CaseInsensitive                 as CI
import           Data.IORef                           (modifyIORef', newIORef,
                                                       readIORef, writeIORef)
import qualified Data.Text.Encoding                   as TE
import           Network.HTTP.Client                  (HttpException (..),
                                                       HttpExceptionContent (..),
                                                       Manager, ManagerSettings,
                                                       defaultManagerSettings,
                                                       managerRawConnection,
                                                       managerSetProxy,
                                                       managerTlsConnection,
                                                       managerWrapException,
                                                       newManager, noProxy)
import           Network.HTTP.Client.Internal         (Connection, makeConnection)

import           Network.HTTP.Client.Cloudflare.Wire

newFetchManager :: IO Manager
newFetchManager = newManager fetchManagerSettings

-- | 'defaultManagerSettings' with both connection factories replaced and
-- proxies disabled (environment proxy variables are ignored). Fetch
-- failures are wrapped as 'ConnectionFailure', bridge errors as
-- 'InternalException'.
fetchManagerSettings :: ManagerSettings
fetchManagerSettings =
  managerSetProxy noProxy $
    defaultManagerSettings
      { managerRawConnection = pure (\_ host port -> fetchConnection "http" host port)
      , managerTlsConnection = pure (\_ host port -> fetchConnection "https" host port)
      , managerWrapException = \req action ->
          action
            `catches` [ Handler (\(e :: F.FetchException) -> throwIO (HttpExceptionRequest req (ConnectionFailure (toException e))))
                      , Handler (\(e :: IOException) -> throwIO (HttpExceptionRequest req (InternalException (toException e))))
                      ]
      }

-- | A one-shot connection: writes accumulate, the first read performs the
-- fetch and returns the whole response, later reads return EOF.
fetchConnection :: B.ByteString -> String -> Int -> IO Connection
fetchConnection scheme host port = do
  written <- newIORef mempty
  answered <- newIORef False
  let write bs = modifyIORef' written (<> BB.byteString bs)
      readConn =
        readIORef answered >>= \case
          True -> pure B.empty
          False -> do
            writeIORef answered True
            raw <- BL.toStrict . BB.toLazyByteString <$> readIORef written
            wire <- either (\why -> ioError (userError ("http-client-cloudflare: " <> why))) pure (parseRequest raw)
            res <- F.fetch (toFetchRequest scheme host port wire)
            body <- F.bytes (F.responseBody res)
            pure (renderResponse (wrMethod wire) (F.status res) (F.statusText res) (F.responseHeaders res) body)
  makeConnection readConn write (pure ())

toFetchRequest :: B.ByteString -> String -> Int -> WireRequest -> F.Request
toFetchRequest scheme host port wire =
  F.request
    { F.method = wrMethod wire
    , F.url = TE.decodeLatin1 (scheme <> "://" <> BC.pack host <> portPart <> encodeTarget (wrTarget wire))
    , F.headers = filter (not . notForwarded . fst) (wrHeaders wire)
    , F.body = if B.null (wrBody wire) then F.noBody else F.bodyBytes (wrBody wire)
      -- http-client follows redirects itself (its own count, cookies and
      -- connections), so fetch must hand the 3xx back.
    , F.redirect = F.Manual
    }
  where
    portPart
      | (scheme, port) `elem` [("https", 443), ("http", 80)] = ""
      | otherwise = ":" <> BC.pack (show port)
    -- Hop-by-hop and fetch-owned headers. http-client always adds Host and
    -- Accept-Encoding; fetch decides both itself.
    notForwarded k =
      CI.foldedCase k
        `elem` [ "host", "content-length", "transfer-encoding", "connection", "keep-alive"
               , "accept-encoding", "expect", "te", "upgrade", "proxy-connection" ]
