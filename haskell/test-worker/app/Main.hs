{-# LANGUAGE OverloadedStrings #-}

-- | A Worker that exercises cloudflare-workers, one route per behaviour.
-- Driven by test/*.test.mjs; not an example to copy.
module Main (main) where

import           Cloudflare.Workers.Context (Context)
import           Cloudflare.Workers.Entry   (runWorker)
import           Cloudflare.Workers.Env     (Env)
import qualified Cloudflare.Workers.Env     as Env
import qualified Cloudflare.Workers.Fetch   as F
import qualified Data.ByteString            as B
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import           System.Environment         (lookupEnv)
import           Text.Read                  (readMaybe)

foreign export javascript "workerMain" main :: IO ()

main :: IO ()
main = runWorker $ \env -> pure (route env)

route :: Env -> F.Request -> Context -> IO F.Response
route env req _ctx =
  case segments (F.url req) of
    ["hello"] -> pure (ok "hello")
    ["status", code]
      | Just n <- readMaybe (T.unpack code) -> pure (F.response n [] (F.bodyText "x"))
    ["body", "echo"] -> F.response 200 [] . F.bodyBytes <$> F.bytes (F.body req)
    ["body", "text"] -> ok <$> F.text (F.body req)
    ["body", "twice"] -> do
      _ <- F.bytes (F.body req)
      ok . T.pack . show . B.length <$> F.bytes (F.body req)
    ["env", "var", name] -> ok <$> Env.var env name
    ["env", "lookup", name] -> ok . T.pack . show <$> Env.lookupVar env name
    ["env", "environ", name] -> ok . T.pack . show <$> lookupEnv (T.unpack name)
    _ -> pure (F.response 404 [] (F.bodyText "not found"))

ok :: Text -> F.Response
ok = F.response 200 [("content-type", "text/plain; charset=utf-8")] . F.bodyText

-- | Path segments of an absolute URL, ignoring the query.
segments :: Text -> [Text]
segments u =
  let afterScheme = T.drop 3 (snd (T.breakOn "://" u))
      path = T.takeWhile (/= '?') (T.dropWhile (/= '/') afterScheme)
   in filter (not . T.null) (T.splitOn "/" path)
