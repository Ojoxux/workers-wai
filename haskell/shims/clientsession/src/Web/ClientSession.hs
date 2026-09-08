-- | Compile-only stand-in for "Web.ClientSession" on @wasm32-wasi@.
--
-- __This shim provides no cryptography.__ It exists so that `yesod-core`, which
-- depends on `clientsession` unconditionally, can be built for a platform where
-- the real implementation's dependency chain (`crypton` -> `memory` ->
-- `basement`) does not compile.
--
-- Applications built against this must disable sessions:
--
-- @
-- instance Yesod App where
--   makeSessionBackend _ = pure Nothing
-- @
--
-- Anything else reaches one of the errors below at runtime. Making sessions work
-- would mean either porting `basement` to WASI, or reimplementing this module
-- against the Workers runtime's WebCrypto @SubtleCrypto@ API through JSFFI.
module Web.ClientSession
  ( Key
  , IV
  , randomIV
  , mkIV
  , getKey
  , getKeyEnv
  , defaultKeyFile
  , getDefaultKey
  , initKey
  , randomKey
  , randomKeyEnv
  , encrypt
  , encryptIO
  , decrypt
  ) where

import qualified Data.ByteString as S

noCrypto :: String -> a
noCrypto name =
  error $
    "clientsession (wasm32-wasi stub): "
      ++ name
      ++ " is not implemented.\n"
      ++ "This build has no AES or Skein, because `basement` does not compile "
      ++ "for wasm32-wasi. Set `makeSessionBackend _ = pure Nothing` in your "
      ++ "Yesod instance, or implement this module against WebCrypto."

-- | Opaque and never constructed.
data Key = Key

instance Eq Key where
  _ == _ = True

instance Show Key where
  show _ = "<Web.ClientSession.Key>"

-- | Opaque and never constructed.
data IV = IV

instance Eq IV where
  _ == _ = True

defaultKeyFile :: FilePath
defaultKeyFile = "client_session_key.aes"

randomIV :: IO IV
randomIV = noCrypto "randomIV"

mkIV :: S.ByteString -> Maybe IV
mkIV _ = noCrypto "mkIV"

getKey :: FilePath -> IO Key
getKey _ = noCrypto "getKey"

getKeyEnv :: String -> IO Key
getKeyEnv _ = noCrypto "getKeyEnv"

getDefaultKey :: IO Key
getDefaultKey = noCrypto "getDefaultKey"

initKey :: S.ByteString -> Either String Key
initKey _ = noCrypto "initKey"

randomKey :: IO (S.ByteString, Key)
randomKey = noCrypto "randomKey"

randomKeyEnv :: String -> IO Key
randomKeyEnv _ = noCrypto "randomKeyEnv"

encrypt :: Key -> IV -> S.ByteString -> S.ByteString
encrypt _ _ _ = noCrypto "encrypt"

encryptIO :: Key -> S.ByteString -> IO S.ByteString
encryptIO _ _ = noCrypto "encryptIO"

decrypt :: Key -> S.ByteString -> Maybe S.ByteString
decrypt _ _ = noCrypto "decrypt"
