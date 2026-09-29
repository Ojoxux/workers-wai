{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The entry point for a Worker.
--
-- worker/src/runtime.mjs calls, in order:
--
-- 1. @setEnv(env, exposeErrors)@, defined here, once per isolate;
-- 2. @workerMain()@, exported by the application, which calls 'runWorker';
-- 3. @handleRequest(request, ctx)@, defined here, for every fetch event.
--
-- An application therefore contains one wasm-specific line:
--
-- @
-- foreign export javascript "workerMain" main :: IO ()
-- @
module Cloudflare.Workers.Entry
  ( Handler
  , runWorker
  ) where

import           Control.Exception                 (SomeException,
                                                    displayException, try)
import           Data.IORef                        (IORef, newIORef, readIORef,
                                                    writeIORef)
import qualified Data.Text                         as T
import           Network.HTTP.Types                (hContentType)
import           System.IO.Unsafe                  (unsafePerformIO)

import           Cloudflare.Workers.Fetch.Internal
import           Cloudflare.Workers.Internal       (Context (..), Env (..))
import           Cloudflare.Workers.Internal.FFI

type Handler = Request -> Context -> IO Response

envRef :: IORef (Maybe Env)
envRef = unsafePerformIO (newIORef Nothing)
{-# NOINLINE envRef #-}

handlerRef :: IORef (Maybe Handler)
handlerRef = unsafePerformIO (newIORef Nothing)
{-# NOINLINE handlerRef #-}

-- | Whether a 500 may carry exception details. Off unless makeWorker was
-- given @exposeErrors: true@.
exposeErrorsRef :: IORef Bool
exposeErrorsRef = unsafePerformIO (newIORef False)
{-# NOINLINE exposeErrorsRef #-}

foreign export javascript "setEnv"
  setEnv :: JSVal -> Bool -> IO ()

setEnv :: JSVal -> Bool -> IO ()
setEnv env exposeErrors = do
  writeIORef exposeErrorsRef exposeErrors
  writeIORef envRef (Just (Env env))

-- | Build the handler from the env, once, and serve every later request
-- with it. Returns immediately: the runtime drives the requests.
runWorker :: (Env -> IO Handler) -> IO ()
runWorker mk = do
  env <-
    readIORef envRef
      >>= maybe
        ( fail $
            "cloudflare-workers: setEnv was not called before workerMain - "
              <> "start the worker with makeWorker from runtime.mjs"
        )
        pure
  handler <- mk env
  writeIORef handlerRef (Just handler)

-- | JSFFI exports are asynchronous: JavaScript sees @Promise<Response>@.
foreign export javascript "handleRequest"
  handleRequest :: JSVal -> JSVal -> IO JSVal

handleRequest :: JSVal -> JSVal -> IO JSVal
handleRequest jsReq jsCtx = do
  -- First, so that a failure anywhere below can still be reported under it.
  ray <- textFromJS <$> js_rayId jsReq
  result <- try $ do
    handler <-
      readIORef handlerRef
        >>= maybe
          ( fail $
              "cloudflare-workers: no handler registered - "
                <> "did workerMain call runWorker?"
          )
          pure
    req <- fromJSRequest jsReq
    res <- handler req (Context jsCtx)
    toJSResponse res
  case result of
    Right jsRes -> pure jsRes
    Left (err :: SomeException) -> do
      let detail = "cloudflare-workers: unhandled exception\n" <> T.pack (displayException err)
          rayLine = "ray: " <> ray <> "\n"
      consoleError (detail <> "\n" <> rayLine)
      exposeErrors <- readIORef exposeErrorsRef
      let body
            | exposeErrors = detail <> "\n" <> rayLine
            | otherwise = "Internal Server Error\n" <> rayLine
      toJSResponse (response 500 [(hContentType, "text/plain; charset=utf-8")] (bodyText body))

-- | The request's @cf-ray@ header, or a fresh UUID when it has none, to tie
-- a 500 body to its @console.error@ line. Wrapped so that it cannot throw.
foreign import javascript unsafe "(() => { try { const r = $1.headers.get('cf-ray'); if (r) return r; } catch {} return crypto.randomUUID(); })()"
  js_rayId :: JSVal -> IO JSString
