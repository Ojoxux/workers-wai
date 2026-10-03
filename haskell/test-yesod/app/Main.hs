{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ViewPatterns #-}

-- | A Yesod app that exercises Yesod.Cloudflare.Session, one route per
-- behaviour, persistent on D1 under /persist, and yesod-static routes served
-- by Workers Static Assets (public/, see test/yesod-wrangler.toml). Driven by
-- test/session.test.mjs and scripts/check-wrangler.mjs; not an example to copy.
--
-- SESSION_BACKEND=clientsession switches to yesod-core's
-- envClientSessionBackend (driven by test/clientsession.test.mjs); otherwise
-- cloudflareSessionBackend.
--
-- The D1 binding DB is optional: without it (as under Node) the /persist
-- routes answer "no DB binding".
module Main (main) where

import qualified Cloudflare.Workers.D1          as D1
import qualified Cloudflare.Workers.Env         as Env
import           Control.Exception              (SomeException, try, tryJust)
import           Data.ByteString                (ByteString)
import qualified Data.ByteString                as B
import           Data.Maybe                     (fromMaybe, maybeToList)
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import           Data.Time                      (Day, UTCTime (..), fromGregorian,
                                                 secondsToDiffTime)
import           Database.Persist
import           Database.Persist.D1            (createD1Pool, d1MigrationSql,
                                                 putManyChunked, repsertManyChunked,
                                                 runD1)
import           Database.Persist.Sql           (runSqlPool, toSqlKey)
import           Database.Persist.TH
import           Network.Wai.Handler.Cloudflare (runCloudflareWith)
import           Text.Read                      (readMaybe)
import           Yesod.Cloudflare.Session
import           Yesod.Cloudflare.Static        (assetsStatic, staticFilesTracked)
import           Yesod.Core
import           Yesod.Static                   (Static)

share [mkPersist sqlSettings, mkMigrate "migrateAll"] [persistLowerCase|
Note
  title Text
  body Text Maybe
  count Int
  ratio Double
  flag Bool
  createdAt UTCTime
  day Day
  blob ByteString
  UniqueTitle title
  deriving Show Eq
|]

-- Two versions of one table, for a migration that changes it.
share [mkPersist sqlSettings, mkMigrate "migrateProbeV1"] [persistLowerCase|
ProbeV1 sql=probe
  name Text
|]

share [mkPersist sqlSettings, mkMigrate "migrateProbeV2"] [persistLowerCase|
ProbeV2 sql=probe
  name Text
  size Int default=0
|]

-- Typed routes for public/static (app_js, img_dot_png), as in any Yesod app.
staticFilesTracked "public/static"

data App = App
  { appSessionBackend :: SessionBackend
  , appDb             :: Maybe D1.D1Database
  , appStatic         :: Static
  }

mkYesod "App" [parseRoutes|
/static     StaticR    Static appStatic
/static-url StaticUrlR GET
/count CountR GET
/large LargeR GET
/form  FormR  GET POST
/persist/migration PersistMigrationR GET
/persist/setup     PersistSetupR     GET
/persist/crud      PersistCrudR      GET
/persist/rebuild   PersistRebuildR   GET
/persist/insert/#Text PersistInsertR GET
/persist/types        PersistTypesR  GET
/persist/unique       PersistUniqueR GET
/persist/bulk         PersistBulkR   GET
/persist/pool         PersistPoolR   GET
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

-- | The URLs yesod-static renders for two files, one per line.
getStaticUrlR :: Handler Text
getStaticUrlR = do
  render <- getUrlRender
  pure (T.unlines [render (StaticR app_js), render (StaticR img_dot_png)])

withDb :: (D1.D1Database -> IO Text) -> Handler Text
withDb k = getYesod >>= maybe (pure "no DB binding") (liftIO . k) . appDb

-- | The migration SQL d1MigrationSql would apply, one statement per line.
getPersistMigrationR :: Handler Text
getPersistMigrationR = withDb $ \db -> T.intercalate "\n" <$> d1MigrationSql db migrateAll

-- | Apply the generated migration (tests only; real apps use wrangler d1 migrations).
getPersistSetupR :: Handler Text
getPersistSetupR = withDb $ \db -> do
  stmts <- d1MigrationSql db migrateAll
  mapM_ (\s -> D1.execute db (D1.Statement s [])) stmts
  pure ("applied " <> T.pack (show (length stmts)))

-- | insert, get, a filtered, ordered and limited selectList, update, delete
-- and count.
getPersistCrudR :: Handler Text
getPersistCrudR = withDb $ \db -> runD1 db $ do
  deleteWhere ([] :: [Filter Note])
  let mk t c = Note t Nothing c (fromIntegral c / 2) (even c) epoch (fromGregorian 2026 10 3) "b"
  k1 <- insert (mk "one" 1)
  _ <- insert (mk "two" 2)
  _ <- insert (mk "three" 3)
  got <- get k1
  big <- selectList [NoteCount >=. 2] [Desc NoteCount, LimitTo 1]
  update k1 [NoteCount =. 10]
  updated <- get k1
  delete k1
  n <- count ([] :: [Filter Note])
  pure . T.intercalate " " $
    [ "get=" <> maybe "missing" noteTitle got
    , "top=" <> T.intercalate "," (map (noteTitle . entityVal) big)
    , "updated=" <> maybe "missing" (T.pack . show . noteCount) updated
    , "count=" <> T.pack (show n)
    ]
  where
    epoch = UTCTime (fromGregorian 2026 10 3) (secondsToDiffTime 3600)

sample :: Text -> Int -> Note
sample t c = Note t Nothing c 0.5 False (UTCTime (fromGregorian 2026 10 3) 0) (fromGregorian 2026 10 3) ""

-- | Insert a note titled after the path, then read it back by the returned key.
getPersistInsertR :: Text -> Handler Text
getPersistInsertR t = withDb $ \db -> runD1 db $ do
  k <- insert (sample t 1)
  got <- get k
  pure (maybe "missing" noteTitle got)

-- | Every field type of Note survives a write and a read.
getPersistTypesR :: Handler Text
getPersistTypesR = withDb $ \db -> runD1 db $ do
  let v = Note "types" (Just "body é😀") (-42) 2.0 True
            (UTCTime (fromGregorian 2026 10 3) (secondsToDiffTime 45296 + 0.123456))
            (fromGregorian 1999 12 31) (B.pack [0, 1, 254, 255])
  deleteBy (UniqueTitle "types")
  k <- insert v
  got <- get k
  pure (if got == Just v then "ok" else T.pack (show (got, v)))

-- | A second note with the same title is rejected by UniqueTitle.
getPersistUniqueR :: Handler Text
getPersistUniqueR = withDb $ \db -> do
  runD1 db (deleteBy (UniqueTitle "dup") >> insert_ (sample "dup" 1))
  r <- try (runD1 db (insert_ (sample "dup" 2)))
  -- stored=1 also shows that insert_ wrote the first note.
  n <- runD1 db (count [NoteTitle ==. "dup"])
  let outcome = either (\(e :: SomeException) -> verdict (T.pack (show e))) (const "accepted") r
      verdict e = if "UNIQUE" `T.isInfixOf` e then "rejected" else "failed: " <> T.take 80 e
  pure (outcome <> " stored=" <> T.pack (show n))

-- | Bulk writes over more parameters than one D1 statement takes (8 per
-- putMany row, 9 per repsertMany row): insertMany_ is split by persistent,
-- putManyChunked and repsertManyChunked split themselves, and a plain putMany
-- that is too big is rejected as a whole.
getPersistBulkR :: Handler Text
getPersistBulkR = withDb $ \db -> do
  runD1 db $ do
    deleteWhere [NoteTitle <-. titles]
    deleteWhere [NoteId <-. repKeys]
    insertMany_ [sample (bulkTitle i) i | i <- [1 .. 40]]
    -- 30 existing rows updated, 10 new ones inserted
    putManyChunked [sample (bulkTitle i) (i * 100) | i <- [11 .. 50]]
    repsertManyChunked [(k, sample ("rep-" <> T.pack (show i)) i) | (i, k) <- zip [1 :: Int ..] repKeys]
  unchunked <- try (runD1 db (putMany [sample (bulkTitle i) 0 | i <- [1 .. 20]]))
  runD1 db $ do
    n <- count [NoteTitle <-. titles]
    reps <- count [NoteId <-. repKeys]
    counts <- mapM (\i -> maybe (-1) (noteCount . entityVal) <$> getBy (UniqueTitle (bulkTitle i))) [1, 11, 50]
    pure $ T.unwords
      [ "count=" <> T.pack (show n)
      , "reps=" <> T.pack (show reps)
      , "counts=" <> T.intercalate "," (map (T.pack . show) counts)
      , "unchunked=" <> either (\(_ :: SomeException) -> "rejected") (const "accepted") unchunked
      ]
  where
    bulkTitle i = "bulk-" <> T.pack (show (i :: Int))
    titles = map bulkTitle [1 .. 50]
    repKeys = [toSqlKey (900000 + fromIntegral i) | i <- [1 .. 15 :: Int]]

-- | insert and get through createD1Pool and runSqlPool.
getPersistPoolR :: Handler Text
getPersistPoolR = withDb $ \db -> do
  pool <- createD1Pool db
  flip runSqlPool pool $ do
    deleteBy (UniqueTitle "pooled")
    maybe "missing" noteTitle <$> (insert (sample "pooled" 7) >>= get)

-- | Changing a table: persistent-sqlite rebuilds it through a backup copy,
-- which must work on D1 and keep the rows.
getPersistRebuildR :: Handler Text
getPersistRebuildR = withDb $ \db -> do
  let run = mapM_ (\s -> D1.execute db (D1.Statement s []))
  run ["DROP TABLE IF EXISTS probe", "DROP TABLE IF EXISTS probe_backup"]
  run =<< d1MigrationSql db migrateProbeV1
  _ <- runD1 db (insert (ProbeV1 "kept"))
  steps <- d1MigrationSql db migrateProbeV2
  run steps
  rows <- runD1 db (selectList ([] :: [Filter ProbeV2]) [])
  left <- d1MigrationSql db migrateProbeV2
  pure $ T.unwords
    [ "steps=" <> T.pack (show (length steps))
    , "rows=" <> T.intercalate "," [probeV2Name r <> ":" <> T.pack (show (probeV2Size r)) | Entity _ r <- rows]
    , "left=" <> T.pack (show (length left))
    ]

foreign export javascript "workerMain" main :: IO ()

main :: IO ()
main = runCloudflareWith $ \env -> do
  kind <- Env.lookupVar env "SESSION_BACKEND"
  backend <- case kind of
    Just "clientsession" -> envClientSessionBackend 120 "SESSION_KEY"
    _ -> do
      current <- Env.var env "SESSION_KEY"
      old <- Env.lookupVar env "SESSION_KEY_OLD"
      minutes <- maybe 120 (read . T.unpack) <$> Env.lookupVar env "SESSION_MINUTES"
      cloudflareSessionBackend (SessionKeys current (maybeToList old)) minutes
  db <- either (const Nothing) Just <$> tryJust missing (D1.d1 env "DB")
  toWaiAppPlain (App backend db assetsStatic)
  where
    -- Only a missing binding is tolerated; a DB bound to something else
    -- still fails.
    missing (Env.EnvMissing _) = Just ()
    missing _                  = Nothing
