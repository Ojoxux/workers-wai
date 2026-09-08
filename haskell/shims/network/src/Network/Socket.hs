{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- | A compile-only stand-in for "Network.Socket" on @wasm32-wasi@.
--
-- WASI preview 1 has no sockets, and the real `network` package does not build
-- against wasi-libc, which ships @sys/socket.h@ but no @netdb.h@. Yet the whole
-- WAI stack depends on it: `wai` for @remoteHost :: SockAddr@, and `warp`,
-- `http2`, `recv` and `streaming-commons` for real socket operations —
-- and `yesod-core` depends on `warp` directly.
--
-- On Cloudflare Workers none of that code ever runs: the runtime owns the
-- connection and hands us a @Request@. So this module provides the types those
-- packages need to typecheck, and operations that fail loudly if anything ever
-- calls them.
--
-- The address types are real, because WAI genuinely uses them. Everything that
-- would touch a file descriptor is 'noSockets'.
module Network.Socket
  ( -- * Addresses
    SockAddr (..)
  , PortNumber
  , defaultPort
  , HostAddress
  , HostAddress6
  , FlowInfo
  , ScopeID
  , HostName
  , ServiceName
  , hostAddressToTuple
  , tupleToHostAddress
  , hostAddress6ToTuple
  , tupleToHostAddress6

    -- * Address resolution
  , AddrInfo (..)
  , AddrInfoFlag (..)
  , defaultHints
  , getAddrInfo

    -- * Socket types
  , Socket
  , Family (..)
  , SocketType (..)
  , ProtocolNumber
  , defaultProtocol
  , SocketOption (..)
  , isSupportedSocketOption
  , ShutdownCmd (..)

    -- * Operations
  , socket
  , bind
  , listen
  , accept
  , connect
  , close
  , gracefulClose
  , shutdown
  , maxListenQueue
  , getSocketName
  , getPeerName
  , socketPort
  , setSocketOption
  , getSocketOption
  , recvBuf
  , recvBufNoWait
  , sendBuf
  , waitReadSocketSTM
  , waitWriteSocketSTM
  , fdSocket
  , withFdSocket
  , mkSocket
  , withSocketsDo
  ) where

import           Control.Concurrent.STM (STM)
import           Data.Bits    (shiftL, shiftR, (.&.), (.|.))
import           Data.List    (intercalate)
import           Data.Word    (Word16, Word32, Word8)
import           Foreign.C    (CInt)
import           Foreign.Ptr  (Ptr)
import           GHC.Generics (Generic)
import           Numeric      (showHex)

-- | Every socket operation lands here.
noSockets :: String -> a
noSockets name =
  error $
    "network (wasm32-wasi stub): "
      ++ name
      ++ " is not available.\n"
      ++ "This platform has no sockets. On Cloudflare Workers the runtime owns "
      ++ "the connection; a WAI Application is driven by "
      ++ "Network.Wai.Handler.Cloudflare instead of by a server."

-- ---------------------------------------------------------------------------
-- Addresses
-- ---------------------------------------------------------------------------

-- | An IPv4 address, in network byte order, as the real package represents it.
type HostAddress = Word32

-- | An IPv6 address as four 32-bit words.
type HostAddress6 = (Word32, Word32, Word32, Word32)

type FlowInfo = Word32

type ScopeID = Word32

type HostName = String

type ServiceName = String

newtype PortNumber = PortNum Word16
  deriving (Eq, Ord, Enum, Num, Real, Integral, Bounded, Generic)

instance Show PortNumber where
  showsPrec p (PortNum n) = showsPrec p n

instance Read PortNumber where
  readsPrec n = map (\(x, s) -> (PortNum x, s)) . readsPrec n

defaultPort :: PortNumber
defaultPort = 0

data SockAddr
  = SockAddrInet PortNumber HostAddress
  | SockAddrInet6 PortNumber FlowInfo HostAddress6 ScopeID
  | SockAddrUnix String
  deriving (Eq, Ord, Generic)

-- | Matches the real package's rendering, which some WAI middleware logs
-- verbatim.
instance Show SockAddr where
  showsPrec _ (SockAddrUnix path) = showString path
  showsPrec _ (SockAddrInet port addr) =
    showString (showHostAddress addr) . showChar ':' . shows port
  showsPrec _ (SockAddrInet6 port _ addr _) =
    showChar '[' . showString (showHostAddress6 addr) . showString "]:" . shows port

showHostAddress :: HostAddress -> String
showHostAddress addr =
  let (a, b, c, d) = hostAddressToTuple addr
   in intercalate "." (map show [a, b, c, d])

showHostAddress6 :: HostAddress6 -> String
showHostAddress6 addr =
  let (a, b, c, d, e, f, g, h) = hostAddress6ToTuple addr
   in intercalate ":" (map (`showHex` "") [a, b, c, d, e, f, g, h])

hostAddressToTuple :: HostAddress -> (Word8, Word8, Word8, Word8)
hostAddressToTuple addr = (byte 24, byte 16, byte 8, byte 0)
  where
    byte n = fromIntegral ((addr `shiftR` n) .&. 0xff)

tupleToHostAddress :: (Word8, Word8, Word8, Word8) -> HostAddress
tupleToHostAddress (a, b, c, d) =
  (fromIntegral a `shiftL` 24)
    .|. (fromIntegral b `shiftL` 16)
    .|. (fromIntegral c `shiftL` 8)
    .|. fromIntegral d

hostAddress6ToTuple ::
  HostAddress6 -> (Word16, Word16, Word16, Word16, Word16, Word16, Word16, Word16)
hostAddress6ToTuple (w0, w1, w2, w3) =
  case concatMap split [w0, w1, w2, w3] of
    [a, b, c, d, e, f, g, h] -> (a, b, c, d, e, f, g, h)
    _                        -> error "hostAddress6ToTuple: impossible"
  where
    split w = [fromIntegral (w `shiftR` 16), fromIntegral (w .&. 0xffff)]

tupleToHostAddress6 ::
  (Word16, Word16, Word16, Word16, Word16, Word16, Word16, Word16) -> HostAddress6
tupleToHostAddress6 (a, b, c, d, e, f, g, h) =
  (joinW a b, joinW c d, joinW e f, joinW g h)
  where
    joinW hi lo = (fromIntegral hi `shiftL` 16) .|. fromIntegral lo

-- ---------------------------------------------------------------------------
-- Socket types
-- ---------------------------------------------------------------------------

-- | Opaque, and never constructed: there is no file descriptor behind it.
newtype Socket = Socket CInt
  deriving (Eq, Ord, Show)

data Family
  = AF_UNSPEC
  | AF_UNIX
  | AF_INET
  | AF_INET6
  deriving (Eq, Ord, Show, Read)

data SocketType
  = NoSocketType
  | Stream
  | Datagram
  | Raw
  | RDM
  | SeqPacket
  deriving (Eq, Ord, Show, Read)

type ProtocolNumber = CInt

defaultProtocol :: ProtocolNumber
defaultProtocol = 0

data SocketOption
  = ReuseAddr
  | ReusePort
  | NoDelay
  | KeepAlive
  | Broadcast
  | Linger
  | SendBuffer
  | RecvBuffer
  | IPv6Only
  | UserTimeout
  | Cork
  deriving (Eq, Ord, Show, Read)

-- | Nothing is supported, because nothing is real.
isSupportedSocketOption :: SocketOption -> Bool
isSupportedSocketOption _ = False

data ShutdownCmd
  = ShutdownReceive
  | ShutdownSend
  | ShutdownBoth
  deriving (Eq, Ord, Show, Read)

data AddrInfo = AddrInfo
  { addrFlags      :: [AddrInfoFlag]
  , addrFamily     :: Family
  , addrSocketType :: SocketType
  , addrProtocol   :: ProtocolNumber
  , addrAddress    :: SockAddr
  , addrCanonName  :: Maybe String
  }
  deriving (Eq, Show)

data AddrInfoFlag
  = AI_ADDRCONFIG
  | AI_ALL
  | AI_CANONNAME
  | AI_NUMERICHOST
  | AI_NUMERICSERV
  | AI_PASSIVE
  | AI_V4MAPPED
  deriving (Eq, Ord, Show, Read)

defaultHints :: AddrInfo
defaultHints =
  AddrInfo
    { addrFlags = []
    , addrFamily = AF_UNSPEC
    , addrSocketType = NoSocketType
    , addrProtocol = defaultProtocol
    , addrAddress = SockAddrInet 0 0
    , addrCanonName = Nothing
    }

maxListenQueue :: Int
maxListenQueue = 128

-- ---------------------------------------------------------------------------
-- Operations
-- ---------------------------------------------------------------------------

getAddrInfo :: Maybe AddrInfo -> Maybe HostName -> Maybe ServiceName -> IO [AddrInfo]
getAddrInfo _ _ _ = noSockets "getAddrInfo"

socket :: Family -> SocketType -> ProtocolNumber -> IO Socket
socket _ _ _ = noSockets "socket"

bind :: Socket -> SockAddr -> IO ()
bind _ _ = noSockets "bind"

listen :: Socket -> Int -> IO ()
listen _ _ = noSockets "listen"

accept :: Socket -> IO (Socket, SockAddr)
accept _ = noSockets "accept"

connect :: Socket -> SockAddr -> IO ()
connect _ _ = noSockets "connect"

close :: Socket -> IO ()
close _ = noSockets "close"

gracefulClose :: Socket -> Int -> IO ()
gracefulClose _ _ = noSockets "gracefulClose"

shutdown :: Socket -> ShutdownCmd -> IO ()
shutdown _ _ = noSockets "shutdown"

getSocketName :: Socket -> IO SockAddr
getSocketName _ = noSockets "getSocketName"

getPeerName :: Socket -> IO SockAddr
getPeerName _ = noSockets "getPeerName"

socketPort :: Socket -> IO PortNumber
socketPort _ = noSockets "socketPort"

setSocketOption :: Socket -> SocketOption -> Int -> IO ()
setSocketOption _ _ _ = noSockets "setSocketOption"

getSocketOption :: Socket -> SocketOption -> IO Int
getSocketOption _ _ = noSockets "getSocketOption"

recvBuf :: Socket -> Ptr Word8 -> Int -> IO Int
recvBuf _ _ _ = noSockets "recvBuf"

recvBufNoWait :: Socket -> Ptr Word8 -> Int -> IO Int
recvBufNoWait _ _ _ = noSockets "recvBufNoWait"

sendBuf :: Socket -> Ptr Word8 -> Int -> IO Int
sendBuf _ _ _ = noSockets "sendBuf"

-- | Yields the STM action that becomes ready when the socket is, matching the
-- shape `warp` expects from network >= 3.2.2.
waitReadSocketSTM :: Socket -> IO (STM ())
waitReadSocketSTM _ = noSockets "waitReadSocketSTM"

waitWriteSocketSTM :: Socket -> IO (STM ())
waitWriteSocketSTM _ = noSockets "waitWriteSocketSTM"

fdSocket :: Socket -> IO CInt
fdSocket _ = noSockets "fdSocket"

withFdSocket :: Socket -> (CInt -> IO r) -> IO r
withFdSocket _ _ = noSockets "withFdSocket"

mkSocket :: CInt -> IO Socket
mkSocket _ = noSockets "mkSocket"

-- | Harmless, and genuinely a no-op on non-Windows platforms.
withSocketsDo :: IO a -> IO a
withSocketsDo = id
