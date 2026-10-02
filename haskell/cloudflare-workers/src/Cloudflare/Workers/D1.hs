{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Cloudflare D1.
--
-- @
-- db <- d1 env \"DB\"
-- D1Rows cols rs <- query db (Statement \"SELECT id, name FROM users WHERE id = ?\" [D1Integer 1])
-- @
--
-- Values cross as JavaScript values, so integers are exact only within
-- ±(2^53 − 1): binding or reading one outside that range throws
-- 'D1Exception' instead of silently rounding. JavaScript numbers do not
-- distinguish integers from reals, so a REAL column holding @1.0@ comes back
-- as @D1Integer 1@.
module Cloudflare.Workers.D1
  ( D1Database
  , d1
  , D1Value (..)
  , Statement (..)
  , D1Rows (..)
  , D1RunResult (..)
  , query
  , execute
  , batch
  , D1Exception (..)
  ) where

import           Control.Exception               (Exception (..), throwIO, try)
import           Control.Monad                   (forM, forM_, unless, when,
                                                  (>=>))
import qualified Data.ByteString                 as B
import           Data.Int                        (Int64)
import           Data.Text                       (Text)
import qualified Data.Text                       as T

import           Cloudflare.Workers.Env          (Env, EnvException (..))
import           Cloudflare.Workers.Internal     (lookupBinding)
import           Cloudflare.Workers.Internal.FFI

-- | A D1 database binding.
newtype D1Database = D1Database JSVal

data D1Value
  = D1Null
  | D1Integer Int64
  | D1Real Double
  | D1Text Text
  | D1Blob B.ByteString
  deriving (Eq, Show)

-- | SQL with positional @?@ parameters.
data Statement = Statement
  { statementSql    :: Text
  , statementParams :: [D1Value]
  }
  deriving (Eq, Show)

-- | Column names and rows, in column order; duplicate names are kept.
data D1Rows = D1Rows
  { columnNames :: [Text]
  , rows        :: [[D1Value]]
  }
  deriving (Eq, Show)

data D1RunResult = D1RunResult
  { changes   :: Int
  , lastRowId :: Int64
    -- ^ SQLite's last_insert_rowid; 0 when nothing was inserted.
  }
  deriving (Eq, Show)

-- | An error reported by D1 (syntax, constraint, ...) or an integer outside
-- the exactly representable range.
newtype D1Exception = D1Exception {d1Message :: Text}
  deriving (Show)

instance Exception D1Exception where
  displayException e = "d1: " <> T.unpack (d1Message e)

-- | The D1 binding with this name. Throws 'EnvMissing' if absent and
-- 'D1Exception' if the binding is something else.
d1 :: Env -> Text -> IO D1Database
d1 env name =
  lookupBinding env name >>= \case
    Nothing -> throwIO (EnvMissing name)
    Just v -> do
      isD1 <- js_isD1 v
      unless isD1 (throwIO (D1Exception ("binding " <> name <> " is not a D1 database")))
      pure (D1Database v)

-- | Rows of a statement (@.raw({ columnNames: true })@).
query :: D1Database -> Statement -> IO D1Rows
query (D1Database db) (Statement q ps) = do
  params <- paramsToJS ps
  raw <- d1Call (js_query db (textToJS q) params)
  n <- js_length raw
  if n == 0
    then pure (D1Rows [] [])
    else do
      names <- js_index raw 0
      nameCount <- js_length names
      cols <- forM [0 .. nameCount - 1] (fmap textFromJS . js_indexString names)
      rs <- forM [1 .. n - 1] $ \r -> do
        row <- js_index raw r
        width <- js_length row
        forM [0 .. width - 1] (js_index row >=> decodeCell)
      pure (D1Rows cols rs)

-- | Run a statement for its effect (@.run()@).
execute :: D1Database -> Statement -> IO D1RunResult
execute (D1Database db) (Statement q ps) = do
  params <- paramsToJS ps
  runResult =<< d1Call (js_execute db (textToJS q) params)

-- | Run statements as one atomic batch (@db.batch()@): if any fails, none
-- takes effect.
batch :: D1Database -> [Statement] -> IO [D1RunResult]
batch (D1Database db) stmts = do
  arr <- js_newArray
  forM_ stmts $ \(Statement q ps) -> paramsToJS ps >>= js_pushPair arr (textToJS q)
  results <- d1Call (js_batch db arr)
  n <- js_length results
  forM [0 .. n - 1] (js_index results >=> runResult)

runResult :: JSVal -> IO D1RunResult
runResult r = do
  c <- js_indexNumber r 0
  rowId <- js_indexNumber r 1
  pure D1RunResult {changes = truncate c, lastRowId = truncate rowId}

maxExact :: Int64
maxExact = 9007199254740991

paramsToJS :: [D1Value] -> IO JSVal
paramsToJS vs = do
  arr <- js_newArray
  forM_ vs $ \case
    D1Null -> js_pushNull arr
    D1Integer n -> do
      when (n > maxExact || n < negate maxExact) $
        throwIO (D1Exception ("integer " <> T.pack (show n) <> " is outside the range D1 represents exactly (±(2^53 - 1))"))
      js_pushNumber arr (fromIntegral n)
    D1Real x -> js_pushNumber arr x
    D1Text t -> js_pushString arr (textToJS t)
    D1Blob b -> toJSBytes b >>= js_pushValue arr
  pure arr

-- | Cells arrive tagged by 'js_query': [0] null, [1, n] integer,
-- [2, x] real, [3, s] text, [4, bytes] blob, [5, n] integer that lost
-- precision.
decodeCell :: JSVal -> IO D1Value
decodeCell cell =
  js_cellTag cell >>= \case
    0 -> pure D1Null
    1 -> D1Integer . truncate <$> js_cellNumber cell
    2 -> D1Real <$> js_cellNumber cell
    3 -> D1Text . textFromJS <$> js_cellString cell
    4 -> D1Blob <$> (js_cellValue cell >>= fromJSBytes)
    5 -> do
      x <- js_cellNumber cell
      throwIO (D1Exception ("D1 returned an integer outside the exactly representable range: " <> T.pack (show x)))
    t -> throwIO (D1Exception ("unexpected cell tag " <> T.pack (show t)))

-- | Await a D1 call, turning a rejection into 'D1Exception'.
d1Call :: IO JSVal -> IO JSVal
d1Call act =
  try (awaitJS act) >>= \case
    Right v -> pure v
    Left err -> throwIO (D1Exception (jsErrorMessage err))

-- -- Imports. unsafe ones cannot throw; safe ones go through d1Call. --------

foreign import javascript unsafe "typeof $1?.prepare === 'function' && typeof $1?.batch === 'function'"
  js_isD1 :: JSVal -> IO Bool

foreign import javascript unsafe "[]"
  js_newArray :: IO JSVal

foreign import javascript unsafe "$1.push(null)"
  js_pushNull :: JSVal -> IO ()

foreign import javascript unsafe "$1.push($2)"
  js_pushNumber :: JSVal -> Double -> IO ()

foreign import javascript unsafe "$1.push($2)"
  js_pushString :: JSVal -> JSString -> IO ()

foreign import javascript unsafe "$1.push($2)"
  js_pushValue :: JSVal -> JSVal -> IO ()

foreign import javascript unsafe "$1.push([$2, $3])"
  js_pushPair :: JSVal -> JSString -> JSVal -> IO ()

foreign import javascript unsafe "$1.length"
  js_length :: JSVal -> IO Int

foreign import javascript unsafe "$1[$2]"
  js_index :: JSVal -> Int -> IO JSVal

foreign import javascript unsafe "String($1[$2])"
  js_indexString :: JSVal -> Int -> IO JSString

foreign import javascript unsafe "Number($1[$2])"
  js_indexNumber :: JSVal -> Int -> IO Double

foreign import javascript unsafe "$1[0]"
  js_cellTag :: JSVal -> IO Int

foreign import javascript unsafe "$1[1]"
  js_cellNumber :: JSVal -> IO Double

foreign import javascript unsafe "$1[1]"
  js_cellString :: JSVal -> IO JSString

foreign import javascript unsafe "$1[1]"
  js_cellValue :: JSVal -> IO JSVal

foreign import javascript safe
  "const rows = await $1.prepare($2).bind(...$3).raw({ columnNames: true }); \
  \const tag = (v) => v === null || v === undefined ? [0] \
  \  : typeof v === 'number' ? (Number.isInteger(v) ? (Number.isSafeInteger(v) ? [1, v] : [5, v]) : [2, v]) \
  \  : typeof v === 'bigint' ? (v >= -9007199254740991n && v <= 9007199254740991n ? [1, Number(v)] : [5, Number(v)]) \
  \  : typeof v === 'string' ? [3, v] \
  \  : [4, v instanceof ArrayBuffer ? new Uint8Array(v) \
  \        : ArrayBuffer.isView(v) ? new Uint8Array(v.buffer, v.byteOffset, v.byteLength) \
  \        : Uint8Array.from(v)]; \
  \return rows.length === 0 ? [] : [rows[0], ...rows.slice(1).map((r) => r.map(tag))];"
  js_query :: JSVal -> JSString -> JSVal -> IO JSVal

foreign import javascript safe
  "const r = await $1.prepare($2).bind(...$3).run(); \
  \return [r.meta?.changes ?? 0, r.meta?.last_row_id ?? 0];"
  js_execute :: JSVal -> JSString -> JSVal -> IO JSVal

foreign import javascript safe
  "const rs = await $1.batch($2.map(([q, ps]) => $1.prepare(q).bind(...ps))); \
  \return rs.map((r) => [r.meta?.changes ?? 0, r.meta?.last_row_id ?? 0]);"
  js_batch :: JSVal -> JSVal -> IO JSVal
