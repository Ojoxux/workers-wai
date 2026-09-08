{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The Stage 1 demo: a bare WAI 'Application', no Yesod involved.
--
-- @\/@ returns the fixed string the PoC is measured against. The other routes
-- exercise the parts of the bridge that a fixed string cannot:
--
-- * @\/echo@ dumps the 'Request' the handler built, including the body
-- * @\/stream@ answers with 'responseStream'
module Main (main) where

import qualified Data.ByteString.Builder        as BB
import qualified Data.ByteString.Lazy           as BL
import qualified Data.CaseInsensitive           as CI
import           Network.HTTP.Types             (status200)
import           Network.Wai
import           Network.Wai.Handler.Cloudflare (runCloudflare)

-- | A wasm reactor module has no entry point of its own, so @main@ has to be
-- exported explicitly for the JavaScript side to call it once after
-- instantiation. This is the only wasm-specific line an application needs.
--
-- The name must not collide with a symbol the RTS already declares: @hs_main@,
-- for one, is taken by @rts\/Main.h@ and fails at the C compilation step.
foreign export javascript "waiMain" main :: IO ()

app :: Application
app req respond = case pathInfo req of
  [] ->
    respond $
      responseLBS
        status200
        [("Content-Type", "text/plain")]
        "Hello from WAI on Cloudflare Workers"
  ["stream"] ->
    respond $ responseStream status200 [("Content-Type", "text/plain")] $
      \write flush -> do
        write (BB.stringUtf8 "chunk one\n")
        flush
        write (BB.stringUtf8 "chunk two\n")
  _ -> do
    body <- strictRequestBody req
    respond $
      responseBuilder status200 [("Content-Type", "text/plain")] (describe req body)

-- | Dump the fields of the WAI 'Request' that this handler populates.
describe :: Request -> BL.ByteString -> BB.Builder
describe req body =
  mconcat
    [ line "requestMethod" (BB.byteString (requestMethod req))
    , line "httpVersion" (BB.stringUtf8 (show (httpVersion req)))
    , line "rawPathInfo" (BB.byteString (rawPathInfo req))
    , line "pathInfo" (BB.stringUtf8 (show (pathInfo req)))
    , line "rawQueryString" (BB.byteString (rawQueryString req))
    , line "queryString" (BB.stringUtf8 (show (queryString req)))
    , line "isSecure" (BB.stringUtf8 (show (isSecure req)))
    , line "remoteHost" (BB.stringUtf8 (show (remoteHost req)))
    , line "bodyLength" (BB.stringUtf8 (show (BL.length body)))
    , line "body" (BB.lazyByteString body)
    , BB.stringUtf8 "requestHeaders:\n"
    , mconcat
        [ mconcat
            [ BB.stringUtf8 "  "
            , BB.byteString (CI.original name)
            , BB.stringUtf8 ": "
            , BB.byteString value
            , BB.charUtf8 '\n'
            ]
        | (name, value) <- requestHeaders req
        ]
    ]
  where
    line label value =
      mconcat [BB.stringUtf8 label, BB.stringUtf8 ": ", value, BB.charUtf8 '\n']

main :: IO ()
main = runCloudflare app
