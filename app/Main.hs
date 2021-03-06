{-# OPTIONS_GHC -Wall -Wno-orphans #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
module Main where

import Data.Maybe (fromJust)
import Control.Monad
import Control.Monad.Trans (liftIO)
import Control.Concurrent
import System.Posix.Signals
import Network.Simple.TCP hiding (send)
import Network.Socket (SockAddr(SockAddrCan))
import qualified Data.ByteString.UTF8 as UTF8
import qualified Data.Text as T
import Crypto.Hash.SHA256 (hash)
import qualified Data.ByteString.Base16 as B16
import System.IO (hPutStrLn, stderr)

import Clapi.Server (protocolServer, withListen)
import Clapi.SerialisationProtocol (serialiser)
import Clapi.Serialisation ()
import Clapi.Relay (relay)
import Clapi.Attributor (attributor)
import Clapi.RelayApi (relayApiProto, PathNameable(..))
import Clapi.Protocol ((<<->), Protocol, waitThen, sendFwd, sendRev)
import Clapi.Types (Attributee(..))
import Clapi.Types.Name (mkName)
import Clapi.TH (n)

shower :: (Show a, Show b) => String -> Protocol a a b b IO ()
shower tag = forever $ waitThen (s " -> " sendFwd) (s " <- " sendRev)
  where
    s d act ms = liftIO (putStrLn $ tag ++ d ++ (show ms)) >> act ms

-- FIXME: This is owned by something unsendable and we should reflect that
internalAddr = SockAddrCan 12

instance PathNameable SockAddr where
    pathNameFor (SockAddrCan _) = [n|relay|]
    -- NOTE: Do not persist this as it depends on the form of show
    pathNameFor clientAddr = fromJust $ mkName $ T.pack $ take 8
      $ UTF8.toString $ B16.encode $ hash $ UTF8.fromString $ show clientAddr

main :: IO ()
main =
  do
    tid <- myThreadId
    installHandler keyboardSignal (Catch $ killThread tid) Nothing
    withListen onDraining onTerminated HostAny "1234" $ \(lsock, _) ->
        protocolServer lsock perClientProto totalProto (return ())
  where
    onDraining = hPutStrLn stderr
      "Stopped accepting new connections, waiting for existing clients to disconnect..."
    onTerminated = hPutStrLn stderr "Forcibly quit"
    perClientProto addr =
      ("SomeOne", addr, serialiser <<-> attributor (Attributee "someone"))
    totalProto = shower "total"
      <<-> relayApiProto internalAddr
      <<-> shower "nt"
      <<-> relay mempty
