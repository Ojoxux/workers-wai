{-# LANGUAGE OverloadedStrings #-}

-- | A Worker that exercises cloudflare-workers, one route per behaviour.
-- Driven by test/*.test.mjs; not an example to copy.
module Main (main) where

import           Cloudflare.Workers.Context (Context, waitUntil)
import           Cloudflare.Workers.Entry   (runWorker)
import           Cloudflare.Workers.Env     (Env)
import qualified Cloudflare.Workers.Env     as Env
import qualified Cloudflare.Workers.Fetch   as F
import           Control.Monad              (void)
import qualified Data.ByteString            as B
import qualified Data.ByteString.Char8      as BC
import           Data.CaseInsensitive       (original)
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import           System.Environment         (lookupEnv)
import           Text.Read                  (readMaybe)

foreign export javascript "workerMain" main :: IO ()

main :: IO ()
main = runWorker $ \env -> pure (route env)

route :: Env -> F.Request -> Context -> IO F.Response
route env req ctx =
  case segments (F.url req) of
    ["hello"] -> pure (ok "hello")
    ["status", code]
      | Just n <- readMaybe (T.unpack code) -> pure (F.response n [] (F.bodyText "x"))
    ["body", "echo"] -> F.response 200 [] . F.bodyBytes <$> F.bytes (F.body req)
    ["body", "text"] -> ok <$> F.text (F.body req)
    ["body", "twice"] -> do
      _ <- F.bytes (F.body req)
      ok . T.pack . show . B.length <$> F.bytes (F.body req)
    ["body", "forward-after-read"] -> do
      _ <- F.bytes (F.body req)
      pure (F.response 200 [] (F.body req))
    ["env", "var", name] -> ok <$> Env.var env name
    ["env", "lookup", name] -> ok . T.pack . show <$> Env.lookupVar env name
    ["env", "environ", name] -> ok . T.pack . show <$> lookupEnv (T.unpack name)
    ["fetch", "roundtrip"] -> do
      up <- Env.var env "UPSTREAM"
      res <-
        F.fetch
          F.request
            { F.method = "PUT"
            , F.url = up <> "/echo"
            , F.headers = [("x-test", "hello")]
            , F.body = F.bodyText "payload"
            }
      b <- F.bytes (F.responseBody res)
      pure (F.response (F.status res) [("content-type", "application/json")] (F.bodyBytes b))
    ["fetch", "status", code] -> do
      up <- Env.var env "UPSTREAM"
      res <- F.fetch F.request {F.url = up <> "/status/" <> code}
      pure (ok ("status=" <> T.pack (show (F.status res))))
    ["fetch", "proxy"] -> do
      up <- Env.var env "UPSTREAM"
      F.fetch req {F.url = up <> "/echo"}
    ["fetch", "rewrite"] -> do
      up <- Env.var env "UPSTREAM"
      F.fetch req {F.url = up <> "/echo", F.body = F.bodyText "rewritten"}
    ["fetch", "unreachable"] -> F.fetch F.request {F.url = "http://127.0.0.1:1/"}
    ["fetch", "badurl"] -> F.fetch F.request {F.url = "not a url"}
    ["wait", "beacon"] -> do
      up <- Env.var env "UPSTREAM"
      waitUntil ctx (void (F.fetch F.request {F.url = up <> "/beacon"}))
      pure (ok "queued")
    ["wait", "fail"] -> do
      waitUntil ctx (fail "boom")
      pure (ok "queued")
    ["wait", "hold"] -> do
      up <- Env.var env "UPSTREAM"
      waitUntil ctx (void (F.fetch F.request {F.url = up <> "/hold"}))
      pure (ok "queued")
    ["cookies", "set"] ->
      pure (F.response 200 [("set-cookie", "a=1; Path=/"), ("set-cookie", "b=2; Path=/")] (F.bodyText "ok"))
    ["cookies", "fetched"] -> do
      up <- Env.var env "UPSTREAM"
      res <- F.fetch F.request {F.url = up <> "/cookies"}
      let cookies = [v | (n, v) <- F.responseHeaders res, n == "set-cookie"]
      pure (ok (T.intercalate "|" (map (T.pack . BC.unpack) cookies)))
    ["cookies", "proxy"] -> do
      up <- Env.var env "UPSTREAM"
      F.fetch F.request {F.url = up <> "/cookies"}
    ["headers", "echo"] -> do
      let line (n, v) = T.pack (BC.unpack (original n)) <> ": " <> T.pack (BC.unpack v)
      pure (ok (T.intercalate "\n" (map line (F.headers req))))
    _ -> pure (F.response 404 [] (F.bodyText "not found"))

ok :: Text -> F.Response
ok = F.response 200 [("content-type", "text/plain; charset=utf-8")] . F.bodyText

-- | Path segments of an absolute URL, ignoring the query.
segments :: Text -> [Text]
segments u =
  let afterScheme = T.drop 3 (snd (T.breakOn "://" u))
      path = T.takeWhile (/= '?') (T.dropWhile (/= '/') afterScheme)
   in filter (not . T.null) (T.splitOn "/" path)
