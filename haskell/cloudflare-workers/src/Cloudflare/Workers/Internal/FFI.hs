{-# LANGUAGE OverloadedStrings #-}

-- | The JavaScript boundary, shared by every module in this package.
--
-- Two rules follow from how GHC's wasm JSFFI behaves (see
-- docs/constraints.md):
--
-- * A JavaScript exception thrown inside an @unsafe@ (synchronous) import is
--   not turned into a Haskell exception: it unwinds straight through the RTS
--   and out of the running export. Use @unsafe@ only for snippets that cannot
--   throw. Anything that can goes through a @safe@ import and 'awaitJS'.
--
-- * The result of a @safe@ (asynchronous) import is a thunk that waits for
--   the promise only when forced. Until then neither the effect nor a
--   rejection is observable. 'awaitJS' forces it on the spot.
module Cloudflare.Workers.Internal.FFI
  ( JSVal
  , JSString (..)
  , JSError (..)
  , awaitJS
  , toJSError
  , fromJSBytes
  , toJSBytes
  , headerPairs
  , decodeHeaders
  , textToJS
  , textFromJS
  , bytesToJS
  , bytesFromJS
  , jsNull
  , consoleError
  ) where

import           Control.Exception        (Exception (..), evaluate, throwIO,
                                           try)
import qualified Data.ByteString          as B
import qualified Data.ByteString.Char8    as BC
import qualified Data.ByteString.Internal as BI
import qualified Data.ByteString.Unsafe   as BU
import qualified Data.CaseInsensitive     as CI
import           Data.List                (intercalate)
import           Data.Text                (Text)
import qualified Data.Text                as T
import           Foreign.Ptr              (ptrToWordPtr)
import           GHC.Wasm.Prim            (JSString (..), JSVal, freeJSVal,
                                           fromJSString, toJSString)
import qualified GHC.Wasm.Prim            as Prim
import           Network.HTTP.Types       (Header)

-- ---------------------------------------------------------------------------
-- Exceptions
-- ---------------------------------------------------------------------------

-- | A JavaScript exception, reduced to the three fields every @Error@ has.
--
-- Named @JSError@ rather than @JSException@ to stay distinct from
-- 'GHC.Wasm.Prim.JSException', which is what GHC raises before conversion.
data JSError = JSError
  { jsErrorName    :: Text
  , jsErrorMessage :: Text
  , jsErrorStack   :: Text
  }
  deriving (Show)

instance Exception JSError where
  displayException e = T.unpack (jsErrorName e <> ": " <> jsErrorMessage e)

-- | Run a @safe@ import to completion, converting a rejection to 'JSError'.
awaitJS :: IO a -> IO a
awaitJS act = do
  result <- try (act >>= evaluate)
  case result of
    Right a                   -> pure a
    Left (Prim.JSException v) -> toJSError v >>= throwIO

toJSError :: JSVal -> IO JSError
toJSError v =
  JSError
    <$> (textFromJS <$> js_errorName v)
    <*> (textFromJS <$> js_errorMessage v)
    <*> (textFromJS <$> js_errorStack v)

-- ---------------------------------------------------------------------------
-- Bytes
-- ---------------------------------------------------------------------------

-- | Copy a @Uint8Array@ into a fresh 'B.ByteString'. Frees the 'JSVal'.
fromJSBytes :: JSVal -> IO B.ByteString
fromJSBytes arr = do
  len <- js_byteLength arr
  bs <-
    if len == 0
      then pure B.empty
      else BI.create len $ \ptr ->
        js_writeBytes arr (fromIntegral (ptrToWordPtr ptr)) len
  freeJSVal arr
  pure bs

-- | Copy a 'B.ByteString' into a fresh @Uint8Array@.
--
-- The pointer is valid only during a synchronous import, during which no GC
-- can run; the JavaScript side copies before returning.
toJSBytes :: B.ByteString -> IO JSVal
toJSBytes bs =
  BU.unsafeUseAsCStringLen bs $ \(ptr, len) ->
    js_copyBytes (fromIntegral (ptrToWordPtr ptr)) len

-- ---------------------------------------------------------------------------
-- Headers
-- ---------------------------------------------------------------------------
--
-- Headers cross the boundary as one NUL-separated string of alternating names
-- and values; NUL cannot occur in a header. Bytes map to characters one to one
-- (latin-1), which is how the Fetch spec defines header ByteStrings.

-- | Build a JS array of @[name, value]@ pairs, accepted by @new Headers@.
headerPairs :: [Header] -> IO JSVal
headerPairs hs =
  js_headerPairs . toJSString . intercalate "\NUL" $
    concatMap (\(name, value) -> [BC.unpack (CI.original name), BC.unpack value]) hs

-- | Decode the output of @[...headers].flat().join('\\0')@.
decodeHeaders :: JSString -> [Header]
decodeHeaders js = case fromJSString js of
  ""  -> []
  raw -> pairs (splitOn '\NUL' raw)
  where
    pairs (name : value : rest) = (CI.mk (BC.pack name), BC.pack value) : pairs rest
    pairs _                     = []

splitOn :: Char -> String -> [String]
splitOn sep s = case break (== sep) s of
  (chunk, [])       -> [chunk]
  (chunk, _ : rest) -> chunk : splitOn sep rest

-- ---------------------------------------------------------------------------
-- Strings and misc
-- ---------------------------------------------------------------------------

textToJS :: Text -> JSString
textToJS = toJSString . T.unpack

textFromJS :: JSString -> Text
textFromJS = T.pack . fromJSString

-- | Latin-1: for methods, status text and other ByteString-typed fields.
bytesToJS :: B.ByteString -> JSString
bytesToJS = toJSString . BC.unpack

bytesFromJS :: JSString -> B.ByteString
bytesFromJS = BC.pack . fromJSString

jsNull :: IO JSVal
jsNull = js_null

consoleError :: Text -> IO ()
consoleError = js_consoleError . textToJS

-- ---------------------------------------------------------------------------
-- Imports. All unsafe: none of these can throw.
-- ---------------------------------------------------------------------------

foreign import javascript unsafe "String($1?.name ?? 'Error')"
  js_errorName :: JSVal -> IO JSString

foreign import javascript unsafe "String($1?.message ?? $1)"
  js_errorMessage :: JSVal -> IO JSString

foreign import javascript unsafe "String($1?.stack ?? '')"
  js_errorStack :: JSVal -> IO JSString

foreign import javascript unsafe "$1.length"
  js_byteLength :: JSVal -> IO Int

foreign import javascript unsafe "new Uint8Array(__exports.memory.buffer, $2, $3).set($1)"
  js_writeBytes :: JSVal -> Int -> Int -> IO ()

foreign import javascript unsafe "new Uint8Array(new Uint8Array(__exports.memory.buffer, $1, $2))"
  js_copyBytes :: Int -> Int -> IO JSVal

foreign import javascript unsafe "$1 === '' ? [] : $1.split('\\u0000').flatMap((x, i, a) => i % 2 ? [] : [[x, a[i + 1]]])"
  js_headerPairs :: JSString -> IO JSVal

foreign import javascript unsafe "null"
  js_null :: IO JSVal

foreign import javascript unsafe "console.error($1)"
  js_consoleError :: JSString -> IO ()
