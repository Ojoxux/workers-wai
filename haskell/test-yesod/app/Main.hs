{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}

-- | A Yesod app that exercises Yesod.Cloudflare.Session, one route per
-- behaviour. Driven by test/session.test.mjs; not an example to copy.
module Main (main) where

import qualified Cloudflare.Workers.Env         as Env
import qualified Data.ByteString                as B
import           Data.Maybe                     (fromMaybe, maybeToList)
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import           Network.Wai.Handler.Cloudflare (runCloudflareWith)
import           Text.Read                      (readMaybe)
import           Yesod.Cloudflare.Session
import           Yesod.Core

newtype App = App {appSessionBackend :: SessionBackend}

mkYesod "App" [parseRoutes|
/count CountR GET
/large LargeR GET
/form  FormR  GET POST
|]

instance Yesod App where
  makeSessionBackend = pure . Just . appSessionBackend
  yesodMiddleware = defaultYesodMiddleware . defaultCsrfMiddleware

-- | Counts visits in the session.
getCountR :: Handler Text
getCountR = do
  n <- fromMaybe (0 :: Int) . (>>= readMaybe . T.unpack) <$> lookupSession "count"
  setSession "count" (T.pack (show (n + 1)))
  pure (T.pack (show (n + 1)))

-- | Puts more in the session than a cookie can hold.
getLargeR :: Handler Text
getLargeR = do
  setSessionBS "large" (B.replicate 5000 120)
  pure "set"

-- | The CSRF token for this session.
getFormR :: Handler Text
getFormR = fromMaybe "" . reqToken <$> getRequest

postFormR :: Handler Text
postFormR = pure "ok"

foreign export javascript "workerMain" main :: IO ()

main :: IO ()
main = runCloudflareWith $ \env -> do
  current <- Env.var env "SESSION_KEY"
  old <- Env.lookupVar env "SESSION_KEY_OLD"
  minutes <- maybe 120 (read . T.unpack) <$> Env.lookupVar env "SESSION_MINUTES"
  backend <- cloudflareSessionBackend (SessionKeys current (maybeToList old)) minutes
  toWaiAppPlain (App backend)
