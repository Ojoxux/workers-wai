{-# LANGUAGE OverloadedStrings #-}

-- | The Worker's @env@: Secrets, @vars@ and bindings.
--
-- Secrets and string @vars@ are indistinguishable at runtime, so both are
-- read with 'var'. Typed bindings (D1, KV, ...) live in their own modules,
-- built on 'Cloudflare.Workers.Internal.lookupBinding'.
--
-- The runtime also copies string entries into the process environment (see
-- @envAsEnviron@ in runtime.mjs), so 'System.Environment.lookupEnv' works for
-- code that expects configuration there. This includes Secrets, not only
-- @vars@: any string-valued entry of @env@ is copied unless @envAsEnviron@ is
-- passed as @False@.
module Cloudflare.Workers.Env
  ( Env
  , var
  , lookupVar
  , EnvException (..)
  ) where

import           Control.Exception               (Exception, throwIO)
import           Data.Text                       (Text)

import           Cloudflare.Workers.Internal     (Env, lookupBinding)
import           Cloudflare.Workers.Internal.FFI

data EnvException
  = EnvMissing Text
    -- ^ No entry with this name.
  | EnvTypeMismatch Text Text
    -- ^ The entry exists but is not a string: name, and its JS @typeof@.
  deriving (Show)

instance Exception EnvException

-- | A string entry. Throws 'EnvException' if it is absent or not a string.
var :: Env -> Text -> IO Text
var env name = lookupVar env name >>= maybe (throwIO (EnvMissing name)) pure

-- | A string entry, or 'Nothing' if absent. Throws 'EnvTypeMismatch' if it
-- exists but is not a string.
lookupVar :: Env -> Text -> IO (Maybe Text)
lookupVar env name = do
  found <- lookupBinding env name
  case found of
    Nothing -> pure Nothing
    Just v -> do
      ty <- textFromJS <$> js_typeof v
      if ty == "string"
        then Just . textFromJS <$> js_asString v
        else throwIO (EnvTypeMismatch name ty)

foreign import javascript unsafe "typeof $1"
  js_typeof :: JSVal -> IO JSString

foreign import javascript unsafe "$1"
  js_asString :: JSVal -> IO JSString
