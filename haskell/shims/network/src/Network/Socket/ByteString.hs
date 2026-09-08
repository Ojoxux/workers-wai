-- | Compile-only stand-in for "Network.Socket.ByteString" on @wasm32-wasi@.
--
-- See "Network.Socket" for why this exists.
module Network.Socket.ByteString
  ( recv
  , recvFrom
  , send
  , sendAll
  , sendMany
  , sendTo
  , sendAllTo
  ) where

import           Data.ByteString (ByteString)
import           Network.Socket  (SockAddr, Socket)

noSockets :: String -> a
noSockets name =
  error $
    "network (wasm32-wasi stub): Network.Socket.ByteString."
      ++ name
      ++ " is not available. This platform has no sockets."

recv :: Socket -> Int -> IO ByteString
recv _ _ = noSockets "recv"

recvFrom :: Socket -> Int -> IO (ByteString, SockAddr)
recvFrom _ _ = noSockets "recvFrom"

send :: Socket -> ByteString -> IO Int
send _ _ = noSockets "send"

sendAll :: Socket -> ByteString -> IO ()
sendAll _ _ = noSockets "sendAll"

sendMany :: Socket -> [ByteString] -> IO ()
sendMany _ _ = noSockets "sendMany"

sendTo :: Socket -> ByteString -> SockAddr -> IO Int
sendTo _ _ _ = noSockets "sendTo"

sendAllTo :: Socket -> ByteString -> SockAddr -> IO ()
sendAllTo _ _ _ = noSockets "sendAllTo"
