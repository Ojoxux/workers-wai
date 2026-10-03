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
-- behaviour, and persistent on D1 under /persist. Driven by
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
import           Control.Exception              (SomeException, try)
import           Data.ByteString                (ByteString)
import qualified Data.ByteString                as B
import           Data.Maybe                     (fromMaybe, maybeToList)
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import           Data.Time                      (Day, UTCTime (..), fromGregorian,
                                                 secondsToDiffTime)
import           Database.Persist
import           Database.Persist.D1            (d1MigrationSql, runD1)
import           Database.Persist.TH
import           Network.Wai.Handler.Cloudflare (runCloudflareWith)
import           Text.Read                      (readMaybe)
import           Yesod.Cloudflare.Session
import           Yesod.Core

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

data App = App {appSessionBackend :: SessionBackend, appDb :: Maybe D1.D1Database}

mkYesod "App" [parseRoutes|
/count CountR GET
/large LargeR GET
/form  FormR  GET POST
/persist/migration PersistMigrationR GET
/persist/setup     PersistSetupR     GET
/persist/crud      PersistCrudR      GET
/persist/rebuild   PersistRebuildR   GET
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
  db <- either (\(_ :: SomeException) -> Nothing) Just <$> try (D1.d1 env "DB")
  toWaiAppPlain (App backend db)
