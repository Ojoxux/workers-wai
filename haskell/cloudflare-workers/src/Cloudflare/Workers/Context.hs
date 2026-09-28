{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The per-request @ExecutionContext@.
module Cloudflare.Workers.Context
  ( Context
  , waitUntil
  ) where

import           Control.Exception               (SomeException, catch,
                                                  displayException)
import qualified Data.Text                       as T

import           Cloudflare.Workers.Internal     (Context (..))
import           Cloudflare.Workers.Internal.FFI

-- | Keep the isolate alive until this action finishes, even after the
-- response has been returned. The action runs on its own Haskell thread.
-- An exception in it is written to @console.error@ and otherwise ignored,
-- so background work such as logging never fails the request.
waitUntil :: Context -> IO () -> IO ()
waitUntil (Context ctx) act = do
  callback <- js_asyncCallback (act `catch` report)
  awaitJS (js_waitUntil ctx callback)
  where
    report (err :: SomeException) =
      consoleError ("waitUntil: " <> T.pack (displayException err))

-- | A JS function that runs the action and returns a Promise of its result.
foreign import javascript "wrapper"
  js_asyncCallback :: IO () -> IO JSVal

-- | safe: waitUntil throws if called after the request has finished.
foreign import javascript safe "$1.waitUntil($2())"
  js_waitUntil :: JSVal -> JSVal -> IO ()
