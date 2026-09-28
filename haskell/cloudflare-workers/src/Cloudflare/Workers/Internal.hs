-- | Representations shared across the package, and the hook for writing new
-- bindings: 'lookupBinding' hands back the raw JS value of an env entry
-- (a D1 database, a KV namespace, ...) for a typed wrapper to take over.
--
-- Application code should not need this module.
module Cloudflare.Workers.Internal
  ( Env (..)
  , Context (..)
  , lookupBinding
  ) where

import           Data.Text                       (Text)

import           Cloudflare.Workers.Internal.FFI

-- | The Worker's @env@ object. One per isolate.
newtype Env = Env JSVal

-- | The per-request @ExecutionContext@.
newtype Context = Context JSVal

-- | The env entry with this name, or 'Nothing' when it is absent.
lookupBinding :: Env -> Text -> IO (Maybe JSVal)
lookupBinding (Env env) name = do
  v <- js_get env (textToJS name)
  undef <- js_isUndefined v
  pure (if undef then Nothing else Just v)

foreign import javascript unsafe "$1[$2]"
  js_get :: JSVal -> JSString -> IO JSVal

foreign import javascript unsafe "$1 === undefined"
  js_isUndefined :: JSVal -> IO Bool
