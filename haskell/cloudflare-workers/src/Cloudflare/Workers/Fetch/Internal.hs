{-# LANGUAGE OverloadedStrings #-}

-- | Representation of Fetch API values and their conversion to and from
-- JavaScript. "Cloudflare.Workers.Fetch" is the public face; this module also
-- exposes the constructors, for the rest of the package and for extensions.
module Cloudflare.Workers.Fetch.Internal
  ( -- * Requests
    Request (..)
  , Redirect (..)
  , request
    -- * Bodies
  , Body (..)
  , noBody
  , bodyBytes
  , bodyText
    -- * Responses
  , Response (..)
  , response
  , status
  , statusText
  , responseHeaders
  , responseBody
    -- * JavaScript conversion
  , fromJSRequest
  , fromJSResponse
  , toJSResponse
  , bodyToJS
  ) where

import qualified Data.ByteString                 as B
import           Data.Text                       (Text)
import qualified Data.Text.Encoding              as TE
import           Network.HTTP.Types              (Method, RequestHeaders,
                                                  ResponseHeaders)

import           Cloudflare.Workers.Internal.FFI

-- ---------------------------------------------------------------------------
-- Requests
-- ---------------------------------------------------------------------------

-- | Used both for requests the Worker receives and for requests it sends.
-- Build outgoing ones by updating 'request'.
data Request = Request
  { method   :: Method
  , url      :: Text
    -- ^ Absolute URL.
  , headers  :: RequestHeaders
  , body     :: Body
  , redirect :: Redirect
  }

data Redirect = Follow | Manual | Error
  deriving (Eq, Show)

-- | @GET@, no URL, no headers, no body, follow redirects.
request :: Request
request =
  Request
    { method = "GET"
    , url = ""
    , headers = []
    , body = noBody
    , redirect = Follow
    }

-- ---------------------------------------------------------------------------
-- Bodies
-- ---------------------------------------------------------------------------

-- | Either bytes already held in Haskell, or the unread body of a JavaScript
-- @Request@ / @Response@. 'JSBody' keeps the owning object rather than its
-- stream, so that @bodyUsed@ can be checked before each use.
data Body
  = BytesBody B.ByteString
  | JSBody JSVal

noBody :: Body
noBody = BytesBody B.empty

bodyBytes :: B.ByteString -> Body
bodyBytes = BytesBody

-- | UTF-8 encoded.
bodyText :: Text -> Body
bodyText = BytesBody . TE.encodeUtf8

-- ---------------------------------------------------------------------------
-- Responses
-- ---------------------------------------------------------------------------

data Response = Response
  { rStatus     :: Int
  , rStatusText :: B.ByteString
  , rHeaders    :: ResponseHeaders
  , rBody       :: Body
  , rOriginal   :: Maybe JSVal
    -- ^ The JS @Response@ this came from, if any. Returned to the runtime
    -- as is, so that proxying does not copy the body through wasm memory.
  }

response :: Int -> ResponseHeaders -> Body -> Response
response s hs b =
  Response
    { rStatus = s
    , rStatusText = ""
    , rHeaders = hs
    , rBody = b
    , rOriginal = Nothing
    }

status :: Response -> Int
status = rStatus

statusText :: Response -> B.ByteString
statusText = rStatusText

responseHeaders :: Response -> ResponseHeaders
responseHeaders = rHeaders

responseBody :: Response -> Body
responseBody = rBody

-- ---------------------------------------------------------------------------
-- JavaScript conversion
-- ---------------------------------------------------------------------------

fromJSRequest :: JSVal -> IO Request
fromJSRequest v = do
  m <- js_method v
  u <- js_url v
  hs <- js_headers v
  rd <- js_redirect v
  pure
    Request
      { method = bytesFromJS m
      , url = textFromJS u
      , headers = decodeHeaders hs
      , body = JSBody v
      , redirect = parseRedirect (textFromJS rd)
      }

parseRedirect :: Text -> Redirect
parseRedirect "manual" = Manual
parseRedirect "error"  = Error
parseRedirect _        = Follow

-- | Status, status text and headers are read once, here.
fromJSResponse :: JSVal -> IO Response
fromJSResponse v = do
  s <- js_status v
  st <- js_statusText v
  hs <- js_headers v
  pure
    Response
      { rStatus = s
      , rStatusText = bytesFromJS st
      , rHeaders = decodeHeaders hs
      , rBody = JSBody v
      , rOriginal = Just v
      }

toJSResponse :: Response -> IO JSVal
toJSResponse r = case rOriginal r of
  Just v -> pure v
  Nothing -> do
    hs <- headerPairs (rHeaders r)
    b <- if hasNullBody (rStatus r) then jsNull else bodyToJS (rBody r)
    awaitJS (js_mkResponse b (rStatus r) (bytesToJS (rStatusText r)) hs)

-- | @new Response(body, ...)@ throws for these unless the body is @null@.
hasNullBody :: Int -> Bool
hasNullBody code = code `elem` [101, 204, 205, 304]

-- | A value usable as a @BodyInit@: @null@, a @Uint8Array@, or a stream.
bodyToJS :: Body -> IO JSVal
bodyToJS (BytesBody b)
  | B.null b = jsNull
  | otherwise = toJSBytes b
bodyToJS (JSBody owner) = js_bodyOf owner

-- ---------------------------------------------------------------------------
-- Imports
-- ---------------------------------------------------------------------------

foreign import javascript unsafe "$1.method"
  js_method :: JSVal -> IO JSString

foreign import javascript unsafe "$1.url"
  js_url :: JSVal -> IO JSString

foreign import javascript unsafe "$1.redirect"
  js_redirect :: JSVal -> IO JSString

foreign import javascript unsafe "[...$1.headers].flat().join('\\u0000')"
  js_headers :: JSVal -> IO JSString

foreign import javascript unsafe "$1.status"
  js_status :: JSVal -> IO Int

foreign import javascript unsafe "$1.statusText"
  js_statusText :: JSVal -> IO JSString

foreign import javascript unsafe "$1.body"
  js_bodyOf :: JSVal -> IO JSVal

-- | safe: throws RangeError on a bad status and TypeError on a bad header.
foreign import javascript safe "new Response($1, { status: $2, statusText: $3, headers: $4 })"
  js_mkResponse :: JSVal -> Int -> JSString -> JSVal -> IO JSVal
