-- | The Fetch API: the requests a Worker receives and sends, and responses.
--
-- Designed to be imported qualified:
--
-- @
-- import qualified Cloudflare.Workers.Fetch as F
-- @
module Cloudflare.Workers.Fetch
  ( -- * Requests
    Request (..)
  , Redirect (..)
  , request
    -- * Bodies
  , Body
  , noBody
  , bodyBytes
  , bodyText
  , bytes
  , text
  , BodyAlreadyUsed (..)
    -- * Responses
  , Response
  , response
  , status
  , statusText
  , responseHeaders
  , responseBody
  ) where

import           Cloudflare.Workers.Fetch.Internal
