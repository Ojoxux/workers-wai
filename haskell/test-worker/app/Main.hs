{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A Worker that exercises cloudflare-workers, one route per behaviour.
-- Driven by test/*.test.mjs; not an example to copy.
module Main (main) where

import           Cloudflare.Workers.Context (Context, waitUntil)
import qualified Cloudflare.Workers.Crypto  as Crypto
import qualified Cloudflare.Workers.D1      as D1
import           Cloudflare.Workers.Entry   (runWorker)
import           Cloudflare.Workers.Env     (Env)
import qualified Cloudflare.Workers.Env     as Env
import qualified Cloudflare.Workers.Fetch   as F
import           Control.Exception          (try)
import           Control.Monad              (join, void)
import           Data.Bits                  (shiftL, shiftR, (.&.), (.|.))
import qualified Data.ByteString            as B
import qualified Data.ByteString.Char8      as BC
import           Data.CaseInsensitive       (original)
import           Data.Char                  (ord)
import           Data.Int                   (Int64)
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
    ["d1", "roundtrip"] -> do
      db <- D1.d1 env "DB"
      exec db "CREATE TABLE IF NOT EXISTS vals (i INTEGER, j INTEGER, r REAL, s TEXT, b BLOB, n INTEGER)" []
      exec db "DELETE FROM vals" []
      exec db "INSERT INTO vals VALUES (?, ?, ?, ?, ?, ?)"
        [ D1.D1Integer 9007199254740991
        , D1.D1Integer (-9007199254740991)
        , D1.D1Real 1.5
        , D1.D1Text "héllo"
        , D1.D1Blob (B.pack [0, 255, 16])
        , D1.D1Null
        ]
      ok . renderRows <$> D1.query db (D1.Statement "SELECT i, j, r, s, b, n FROM vals" [])
    ["d1", "empty"] -> do
      db <- D1.d1 env "DB"
      exec db "CREATE TABLE IF NOT EXISTS vals (i INTEGER, j INTEGER, r REAL, s TEXT, b BLOB, n INTEGER)" []
      ok . renderRows <$> D1.query db (D1.Statement "SELECT i FROM vals WHERE 0" [])
    ["d1", "real-one"] -> do
      db <- D1.d1 env "DB"
      exec db "CREATE TABLE IF NOT EXISTS reals (r REAL)" []
      exec db "DELETE FROM reals" []
      exec db "INSERT INTO reals VALUES (?)" [D1.D1Real 1.0]
      ok . renderRows <$> D1.query db (D1.Statement "SELECT r FROM reals" [])
    ["d1", "read-overflow"] -> do
      db <- D1.d1 env "DB"
      ok . renderRows <$> D1.query db (D1.Statement "SELECT 9007199254740993" [])
    ["d1", "empty-batch"] -> do
      db <- D1.d1 env "DB"
      rs <- D1.batch db []
      pure (ok (T.intercalate "," (map (T.pack . show . D1.changes) rs)))
    ["d1", "not-d1"] -> do
      _ <- D1.d1 env "GREETING"
      pure (ok "unreachable")
    ["d1", "text"] -> do
      db <- D1.d1 env "DB"
      exec db "CREATE TABLE IF NOT EXISTS texts (k INTEGER, s TEXT)" []
      exec db "DELETE FROM texts" []
      exec db "INSERT INTO texts VALUES (1, ?), (2, ?)" [D1.D1Text "😀 héllo", D1.D1Text "a\0b"]
      ok . renderRows <$> D1.query db (D1.Statement "SELECT s FROM texts ORDER BY k" [])
    ["d1", "blobs"] -> do
      db <- D1.d1 env "DB"
      exec db "CREATE TABLE IF NOT EXISTS blobs (k INTEGER, b BLOB)" []
      exec db "DELETE FROM blobs" []
      let big = B.pack (map fromIntegral [0 .. 65535 :: Int])
      exec db "INSERT INTO blobs VALUES (1, ?), (2, ?)" [D1.D1Blob B.empty, D1.D1Blob big]
      res <- D1.query db (D1.Statement "SELECT b FROM blobs ORDER BY k" [])
      let describe = \case
            [D1.D1Blob b] -> "blob " <> T.pack (show (B.length b)) <> " " <> T.pack (show (b == B.take (B.length b) big))
            other -> T.pack (show (map (T.take 40 . renderD1) other))
      pure (ok (T.intercalate "\n" (map describe (D1.rows res))))
    ["d1", "rows"] -> do
      db <- D1.d1 env "DB"
      exec db "CREATE TABLE IF NOT EXISTS multi (k INTEGER, v TEXT)" []
      exec db "DELETE FROM multi" []
      exec db "INSERT INTO multi VALUES (2, 'b'), (3, 'c'), (1, 'a')" []
      ok . renderRows <$> D1.query db (D1.Statement "SELECT k, v FROM multi ORDER BY k" [])
    ["d1", "bind-count"] -> do
      db <- D1.d1 env "DB"
      _ <- D1.query db (D1.Statement "SELECT ?, ?" [D1.D1Integer 1])
      pure (ok "unreachable")
    ["d1", "rowid-range", how] -> do
      db <- D1.d1 env "DB"
      exec db "CREATE TABLE IF NOT EXISTS bigids (id INTEGER PRIMARY KEY, v TEXT)" []
      exec db "DELETE FROM bigids" []
      let ins = D1.Statement "INSERT INTO bigids (id, v) VALUES (9007199254740993, 'x')" []
      rs <- if how == "batch" then D1.batch db [ins] else pure <$> D1.execute db ins
      pure (ok (T.intercalate "," (map (T.pack . show . D1.lastRowId) rs)))
    ["d1", "nonfinite", which] -> do
      db <- D1.d1 env "DB"
      let x = if which == "nan" then 0 / 0 else 1 / 0 :: Double
      ok . renderRows <$> D1.query db (D1.Statement "SELECT ?" [D1.D1Real x])
    ["d1", "too-big"] -> do
      db <- D1.d1 env "DB"
      _ <- D1.query db (D1.Statement "SELECT ?" [D1.D1Integer 9007199254740992])
      pure (ok "unreachable")
    ["d1", "run"] -> do
      db <- D1.d1 env "DB"
      exec db "CREATE TABLE IF NOT EXISTS runs (id INTEGER PRIMARY KEY, v TEXT)" []
      exec db "DELETE FROM runs" []
      r <- D1.execute db (D1.Statement "INSERT INTO runs (v) VALUES (?)" [D1.D1Text "x"])
      pure (ok ("changes=" <> T.pack (show (D1.changes r)) <> " lastRowId>0=" <> T.pack (show (D1.lastRowId r > 0))))
    ["d1", "batch"] -> do
      db <- D1.d1 env "DB"
      exec db "CREATE TABLE IF NOT EXISTS uniq (x INTEGER UNIQUE)" []
      exec db "DELETE FROM uniq" []
      rs <- D1.batch db [insertUniq 1, insertUniq 2]
      pure (ok (T.intercalate "," (map (T.pack . show . D1.changes) rs)))
    ["d1", "batch-atomic"] -> do
      db <- D1.d1 env "DB"
      exec db "CREATE TABLE IF NOT EXISTS uniq (x INTEGER UNIQUE)" []
      exec db "DELETE FROM uniq" []
      outcome <- try (D1.batch db [insertUniq 1, insertUniq 1]) :: IO (Either D1.D1Exception [D1.D1RunResult])
      count <- D1.query db (D1.Statement "SELECT COUNT(*) FROM uniq" [])
      let n = case D1.rows count of
            [[v]] -> renderD1 v
            other -> T.pack (show other)
      pure (ok ("batch=" <> either (const "failed") (const "succeeded") outcome <> " count=" <> n))
    ["d1", "syntax"] -> do
      db <- D1.d1 env "DB"
      _ <- D1.query db (D1.Statement "SELEC 1" [])
      pure (ok "unreachable")
    ["d1", "missing"] -> do
      _ <- D1.d1 env "NOPE"
      pure (ok "unreachable")
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

exec :: D1.D1Database -> Text -> [D1.D1Value] -> IO ()
exec db q ps = void (D1.execute db (D1.Statement q ps))

insertUniq :: Int64 -> D1.Statement
insertUniq x = D1.Statement "INSERT INTO uniq (x) VALUES (?)" [D1.D1Integer x]

renderD1 :: D1.D1Value -> Text
renderD1 = \case
  D1.D1Null -> "null"
  D1.D1Integer n -> "int:" <> T.pack (show n)
  D1.D1Real x -> "real:" <> T.pack (show x)
  D1.D1Text t -> "text:" <> t
  D1.D1Blob b -> "blob:" <> toHex b

renderRows :: D1.D1Rows -> Text
renderRows res =
  T.intercalate "," (D1.columnNames res)
    <> "\n"
    <> T.intercalate "\n" (map (T.unwords . map renderD1) (D1.rows res))
