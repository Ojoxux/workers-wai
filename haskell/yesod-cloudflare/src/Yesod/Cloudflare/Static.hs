-- | Serving yesod-static's routes from Workers Static Assets.
--
-- Workers Static Assets serves a request from the assets directory when a
-- file matches its path, without running the Worker, and ignores the query
-- string. Put the files under @static\/@ inside the assets directory and
-- generate the usual typed routes, @\/static\/app.js?etag=…@, with
-- 'staticFilesTracked'; the assets layer answers them directly:
--
-- > -- wrangler.toml:  [assets]
-- > --                 directory = "public"
-- > staticFilesTracked "public/static"
-- >
-- > data App = App { appStatic :: Static, ... }
-- >
-- > mkYesod "App" [parseRoutes|
-- > /static StaticR Static appStatic
-- > ...
-- > |]
-- >
-- > main = runCloudflareWith $ \env -> toWaiAppPlain App { appStatic = assetsStatic, ... }
--
-- Only requests for files that do not exist reach the Worker, and
-- 'assetsStatic' answers them with 404. 'Yesod.Static.static' and
-- 'Yesod.Static.staticDevel' cannot be used: they read the directory when
-- called, and a Worker has no filesystem. For the same reason keep yesod's
-- default 'Yesod.Core.addStaticContent', which inlines generated CSS and
-- JavaScript, rather than @addStaticContentExternal@, which writes files.
module Yesod.Cloudflare.Static
  ( assetsStatic
  , staticFilesTracked
  ) where

import           Control.Monad              (filterM, forM)
import           Language.Haskell.TH        (Dec, Q, runIO)
import           Language.Haskell.TH.Syntax (addDependentFile)
import           Network.Wai.Application.Static (embeddedSettings)
import           System.Directory           (doesDirectoryExist, doesFileExist,
                                             listDirectory)
import           System.FilePath            ((</>))
import           WaiAppStatic.Types         (LookupResult (LRNotFound),
                                             StaticSettings (..))
import           Yesod.Static               (Static (..), staticFiles)

-- | A static subsite that holds no files: every GET or HEAD gets 404, also
-- for the subsite's root (no directory listing). The files themselves are
-- served by Workers Static Assets. wai-app-static still answers 405 to other
-- methods and 403 to paths with a segment starting with a dot.
assetsStatic :: Static
assetsStatic =
  Static (embeddedSettings [])
    { ssLookupFile = \_ -> pure LRNotFound
    , ssListing = Nothing
    }

-- | 'Yesod.Static.staticFiles', plus a dependency on every file it hashes.
--
-- yesod-static puts a hash of each file into its URL (@?etag=…@) at compile
-- time but does not tell GHC about the files, so editing one leaves the old
-- hash in place until the module happens to be recompiled. With
-- long-lived caching of @\/static\/*@, browsers would then keep the old
-- file under the old URL. This makes GHC recompile the module whenever a
-- file changes.
--
-- cabal only runs GHC when a file it knows about changes, so also list the
-- files in the package's @extra-source-files@, one pattern per extension
-- (with @cabal-version: 3.0@, @**@ must be followed by @*.ext@):
--
-- > extra-source-files:
-- >   public/static/**/*.js
-- >   public/static/**/*.png
--
-- A file added later still needs the module recompiled to get a route, as
-- with 'Yesod.Static.staticFiles'.
staticFilesTracked :: FilePath -> Q [Dec]
staticFilesTracked dir = do
  files <- runIO (listFiles dir)
  mapM_ addDependentFile files
  staticFiles dir

-- | Every file under the directory, skipping what yesod-static skips:
-- names starting with a dot, and @tmp@.
listFiles :: FilePath -> IO [FilePath]
listFiles dir = do
  names <- filter visible <$> listDirectory dir
  let paths = map (dir </>) names
  files <- filterM doesFileExist paths
  dirs <- filterM doesDirectoryExist paths
  nested <- forM dirs listFiles
  pure (files ++ concat nested)
  where
    visible ('.' : _) = False
    visible "tmp"     = False
    visible _         = True
