-- | Serving yesod-static's 'StaticR' routes from Workers Static Assets.
--
-- Workers Static Assets serves a request from the assets directory when a
-- file matches its path, without running the Worker, and ignores the query
-- string. Put the files under @static\/@ inside the assets directory and
-- 'staticFiles' produces the usual typed routes, @/static/app.js?etag=…@,
-- which the assets layer answers directly:
--
-- > -- wrangler.toml:  [assets]
-- > --                 directory = "public"
-- > staticFiles "public/static"
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
-- Only requests for files that do not exist reach the Worker, so the
-- subsite itself only has to answer 404. 'Yesod.Static.static' and
-- 'Yesod.Static.staticDevel' cannot be used: they read the directory when
-- called, and a Worker has no filesystem. For the same reason, set
-- 'Yesod.Core.addStaticContent' to @\\_ _ _ -> pure Nothing@ (inline the
-- generated CSS and JavaScript) instead of @addStaticContentExternal@, which
-- writes files.
module Yesod.Cloudflare.Static
  ( assetsStatic
  ) where

import           Network.Wai.Application.Static (embeddedSettings)
import           Yesod.Static                   (Static (..))

-- | A static subsite that holds no files and answers every request with 404.
-- The files themselves are served by Workers Static Assets.
assetsStatic :: Static
assetsStatic = Static (embeddedSettings [])
