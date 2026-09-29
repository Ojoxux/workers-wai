{-# LANGUAGE OverloadedStrings #-}

-- | A Worker that exercises cloudflare-workers, one route per behaviour.
-- Driven by test/*.test.mjs; not an example to copy.
module Main (main) where

import           Cloudflare.Workers.Context (Context, waitUntil)
import qualified Cloudflare.Workers.Crypto  as Crypto
import           Cloudflare.Workers.Entry   (runWorker)
import           Cloudflare.Workers.Env     (Env)
import qualified Cloudflare.Workers.Env     as Env
import qualified Cloudflare.Workers.Fetch   as F
import           Control.Monad              (join, void)
import           Data.Bits                  (shiftL, shiftR, (.&.), (.|.))
import qualified Data.ByteString            as B
import qualified Data.ByteString.Char8      as BC
import           Data.CaseInsensitive       (original)
import           Data.Char                  (ord)
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import           Network.HTTP.Types         (parseQuery)
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
    ["crypto", "seal"]
      | Just [ikm, salt, info, iv, aad, pt] <- params req ["ikm", "salt", "info", "iv", "aad", "pt"] -> do
          key <- Crypto.hkdfAesGcmKey ikm salt info
          ok . toHex <$> Crypto.aesGcmEncrypt key iv aad pt
    ["crypto", "open"]
      | Just [ikm, salt, info, iv, aad, ct] <- params req ["ikm", "salt", "info", "iv", "aad", "ct"] -> do
          key <- Crypto.hkdfAesGcmKey ikm salt info
          ok . maybe "Nothing" toHex <$> Crypto.aesGcmDecrypt key iv aad ct
    ["crypto", "random", n]
      | Just len <- readMaybe (T.unpack n) -> do
          b <- Crypto.randomBytes len
          let tailNonZero = B.any (/= 0) (B.drop (B.length b - 64) b)
          pure (ok (T.pack (show (B.length b) <> " " <> show (B.any (/= 0) b) <> " " <> show tailNonZero)))
    ["crypto", "random-hex", n]
      | Just len <- readMaybe (T.unpack n) -> ok . toHex <$> Crypto.randomBytes len
    ["crypto", "selftest"] -> do
      key <- Crypto.hkdfAesGcmKey (BC.replicate 32 'k') "salt" "info"
      other <- Crypto.hkdfAesGcmKey (BC.replicate 32 'o') "salt" "info"
      iv <- Crypto.randomBytes 12
      ct <- Crypto.aesGcmEncrypt key iv "aad" "payload"
      back <- Crypto.aesGcmDecrypt key iv "aad" ct
      wrongKey <- Crypto.aesGcmDecrypt other iv "aad" ct
      wrongAad <- Crypto.aesGcmDecrypt key iv "other" ct
      tampered <- Crypto.aesGcmDecrypt key iv "aad" (B.map (+ 1) ct)
      pure . ok $
        if back == Just "payload" && wrongKey == Nothing && wrongAad == Nothing && tampered == Nothing
          then "ok"
          else T.pack (show (back, wrongKey, wrongAad, tampered))
    _ -> pure (F.response 404 [] (F.bodyText "not found"))

ok :: Text -> F.Response
ok = F.response 200 [("content-type", "text/plain; charset=utf-8")] . F.bodyText

-- | Path segments of an absolute URL, ignoring the query.
segments :: Text -> [Text]
segments u =
  let afterScheme = T.drop 3 (snd (T.breakOn "://" u))
      path = T.takeWhile (/= '?') (T.dropWhile (/= '/') afterScheme)
   in filter (not . T.null) (T.splitOn "/" path)

-- | Hex-decoded query parameters, in the order asked for; Nothing if any is
-- missing or not valid hex.
params :: F.Request -> [B.ByteString] -> Maybe [B.ByteString]
params req names =
  let query = parseQuery (BC.pack (T.unpack (T.dropWhile (/= '?') (F.url req))))
   in traverse (\n -> join (lookup n query) >>= fromHex) names

toHex :: B.ByteString -> Text
toHex = T.pack . concatMap byte . B.unpack
  where
    byte w = [digit (w `shiftR` 4), digit (w .&. 15)]
    digit d = "0123456789abcdef" !! fromIntegral d

-- | Lowercase only, which is what Node's hex encoding produces.
fromHex :: B.ByteString -> Maybe B.ByteString
fromHex s
  | odd (B.length s) = Nothing
  | otherwise = B.pack <$> traverse pair (chunks (BC.unpack s))
  where
    chunks (a : b : rest) = (a, b) : chunks rest
    chunks _ = []
    pair (a, b) = (\x y -> fromIntegral ((x `shiftL` 4) .|. y)) <$> nibble a <*> nibble b
    nibble c
      | c >= '0' && c <= '9' = Just (ord c - ord '0')
      | c >= 'a' && c <= 'f' = Just (ord c - ord 'a' + 10)
      | otherwise = Nothing
