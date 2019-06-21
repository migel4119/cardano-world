{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE NumericUnderscores  #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-# OPTIONS_GHC -Wno-simplifiable-class-constraints #-}

module Run (
      runNode
    ) where

import           Codec.CBOR.Decoding (Decoder)
import           Codec.CBOR.Encoding (Encoding)
import qualified Codec.Serialise as Serialise (encode, decode)
import           Control.Exception
import           Control.Concurrent (threadDelay)
import qualified Control.Concurrent.Async as Async
import           Control.Monad
import           Control.Tracer
import           Crypto.Random
import           Data.Functor.Contravariant (contramap)
import qualified Data.Map.Strict as M
import           Data.Maybe
import           Data.Semigroup ((<>))
import           Data.ByteString.Lazy (ByteString)

import           Control.Monad.Class.MonadAsync

import           System.IO.Error (isDoesNotExistError)
import           System.Directory (removeFile)
import           Network.Socket as Socket

import qualified Ouroboros.Network.AnchoredFragment as AF
import           Ouroboros.Network.Block
import qualified Ouroboros.Network.Block as Block
import           Ouroboros.Network.Chain (genesisPoint, pointHash)
import qualified Ouroboros.Network.Chain as Chain
import           Ouroboros.Network.NodeToNode   as NodeToNode
import           Ouroboros.Network.NodeToClient as NodeToClient

import           Ouroboros.Network.Protocol.BlockFetch.Codec
import           Ouroboros.Network.Protocol.ChainSync.Codec
import           Ouroboros.Network.Protocol.LocalTxSubmission.Codec
import           Ouroboros.Network.Protocol.Handshake.Type
import           Ouroboros.Network.Protocol.Handshake.Version

import           Ouroboros.Consensus.Block
import           Ouroboros.Consensus.BlockchainTime
import           Ouroboros.Consensus.ChainSyncClient (ClockSkew (..))
import           Ouroboros.Consensus.Demo
import           Ouroboros.Consensus.Demo.Run
import           Ouroboros.Consensus.NodeId
import           Ouroboros.Consensus.Node
import           Ouroboros.Consensus.NodeNetwork
import           Ouroboros.Consensus.Util.Condense
import           Ouroboros.Consensus.Util.Orphans ()
import           Ouroboros.Consensus.Util.STM
import           Ouroboros.Consensus.Util.ThreadRegistry

import           Ouroboros.Storage.ChainDB (ChainDB)
import qualified Ouroboros.Storage.ChainDB as ChainDB
import qualified Ouroboros.Storage.ChainDB.Mock as ChainDB

import           CLI
import           TxSubmission
import           Topology

runNode :: CLI -> IO ()
runNode cli@CLI{..} = do
    -- If the user asked to submit a transaction, we don't have to spin up a
    -- full node, we simply transmit it and exit.
    case command of
      TxSubmitter topology tx ->
        handleTxSubmission topology tx
      SimpleNode topology myNodeAddress protocol -> do
        SomeProtocol p <- fromProtocol protocol
        handleSimpleNode p cli myNodeAddress topology

-- | Sets up a simple node, which will run the chain sync protocol and block
-- fetch protocol, and, if core, will also look at the mempool when trying to
-- create a new block.
handleSimpleNode :: forall blk.  RunDemo blk
                 => DemoProtocol blk -> CLI -> NodeAddress -> TopologyInfo -> IO ()
handleSimpleNode p CLI{..} myNodeAddress (TopologyInfo myNodeId topologyFile) = do
    putStrLn $ "System started at " <> show systemStart
    t@(NetworkTopology nodeSetups) <-
      either error id <$> readTopologyFile topologyFile
    let topology  = toNetworkMap t
        nodeSetup = fromMaybe (error "node not found.") $
                          M.lookup myNodeId topology

    putStrLn $ "**************************************"
    putStrLn $ "I am Node = " <> show myNodeId
    putStrLn $ "My producers are " <> show (producers nodeSetup)
    putStrLn $ "**************************************"

    let ProtocolInfo{pInfoConfig, pInfoInitLedger, pInfoInitState} =
          protocolInfo (NumCoreNodes (length nodeSetups)) (CoreNodeId nid) p

    withThreadRegistry $ \registry -> do

      let callbacks :: NodeCallbacks IO blk
          callbacks = NodeCallbacks {
              produceDRG   = drgNew
            , produceBlock = \proof _l slot prevPoint prevBlockNo txs -> do
                let curNo :: BlockNo
                    curNo = succ prevBlockNo

                    prevHash :: ChainHash blk
                    prevHash = castHash (pointHash prevPoint)

                 -- The transactions we get are consistent; the only reason not
                 -- to include all of them would be maximum block size, which
                 -- we ignore for now.
                demoForgeBlock pInfoConfig
                               slot
                               curNo
                               prevHash
                               txs
                               proof
          }

      chainDB :: ChainDB IO blk (Header blk) <-
        ChainDB.openDB
          pInfoConfig
          pInfoInitLedger
          getHeader

      btime  <- realBlockchainTime registry slotDuration systemStart
      let tracer = contramap ((show myNodeId <> " | ") <>) stdoutTracer

          nodeParams :: NodeParams IO NodeAddress blk
          nodeParams = NodeParams
            { tracer             = tracer
            , threadRegistry     = registry
            , maxClockSkew       = ClockSkew 1
            , cfg                = pInfoConfig
            , initState          = pInfoInitState
            , btime
            , chainDB
            , callbacks
            , blockFetchSize     = demoBlockFetchSize
            , blockMatchesHeader = demoBlockMatchesHeader
            }

      kernel <- nodeKernel nodeParams

      let networkApps :: NetworkApplication
                           IO NodeAddress
                           ByteString ByteString
                           ByteString ByteString ()
          networkApps =
            consensusNetworkApps
              nullTracer
              nullTracer
              kernel
              ProtocolCodecs
                { pcChainSyncCodec =
                    codecChainSync
                      (demoEncodeHeader pInfoConfig)
                      (demoDecodeHeader pInfoConfig)
                       encodePoint'
                       decodePoint'

                , pcBlockFetchCodec =
                    codecBlockFetch
                      (demoEncodeBlock pInfoConfig)
                      demoEncodeHeaderHash
                      (demoDecodeBlock pInfoConfig)
                      demoDecodeHeaderHash

                , pcLocalChainSyncCodec =
                    codecChainSync
                      (demoEncodeBlock pInfoConfig)
                      (demoDecodeBlock pInfoConfig)
                       encodePoint'
                       decodePoint'

                , pcLocalTxSubmissionCodec =
                    codecLocalTxSubmission
                      demoEncodeGenTx
                      demoDecodeGenTx
                      Serialise.encode
                      Serialise.decode

                }
              (protocolHandlers nodeParams kernel)

      let networkAppNodeToNode :: Versions
                                    NodeToNodeVersion
                                    DictVersion
                                    (NetworkApplication
                                       IO NodeAddress
                                       ByteString ByteString
                                       ByteString ByteString ())
          networkAppNodeToNode =
            simpleSingletonVersions
              NodeToNodeV_1
              (NodeToNodeVersionData { networkMagic = 0 })
              (DictVersion nodeToNodeCodecCBORTerm)
              networkApps

      let networkAppNodeToClient :: Versions
                                      NodeToClientVersion
                                      DictVersion
                                      (NetworkApplication
                                         IO NodeAddress
                                         ByteString ByteString
                                         ByteString ByteString ())
          networkAppNodeToClient =
            simpleSingletonVersions
              NodeToClientV_1
              (NodeToClientVersionData { networkMagic = 0 })
              (DictVersion nodeToClientCodecCBORTerm)
              networkApps

      watchChain registry tracer chainDB

      myAddr:_ <- case myNodeAddress of
        NodeAddress host port -> getAddrInfo Nothing (Just host) (Just port)

      let myLocalSockPath = localSocketFilePath myNodeId
          myLocalAddr     = localSocketAddrInfo myLocalSockPath
      removeStaleLocalSocket myLocalSockPath

      -- TODO: cheap subscription managment, a proper one is on the way.  The
      -- point is that it only requires 'NetworkApplications' which is a thin
      -- layer around 'MuxApplication'.

      -- serve local clients (including tx submission)
      localServer <-
        forkLinked registry $
          NodeToClient.withServer
            myLocalAddr
            (\(DictVersion _) -> acceptEq)
            (muxLocalResponderNetworkApplication <$> networkAppNodeToClient)
            wait

      -- serve downstream nodes
      peerServer <-
        forkLinked registry $
          NodeToNode.withServer
            myAddr (\(DictVersion _) -> acceptEq)
            (muxResponderNetworkApplication <$> networkAppNodeToNode)
            wait

      -- connect to upstream nodes
      forM_ (producers nodeSetup) $ \na@(NodeAddress host port) ->
        forkLinked registry $ do

          let io = do
                addr:_ <- getAddrInfo Nothing (Just host) (Just port)
                NodeToNode.connectTo
                      (muxInitiatorNetworkApplication na <$> networkAppNodeToNode)
                      -- Do not bind to a local port, use ephemeral
                      -- one.  We cannot bind to port on which the server is
                      -- already accepting connections.
                      Nothing
                      addr
                  -- TODO: this is purposefully simple, a proper DNS management
                  -- is on the way in PR #607
                  `catch` \(_ :: IOException) -> threadDelay 250_000 >> io

          io

      _ <- Async.waitAny [localServer, peerServer]
      return ()
  where
      nid :: Int
      nid = case myNodeId of
              CoreId  n -> n
              RelayId _ -> error "Non-core nodes currently not supported"

      watchChain :: ThreadRegistry IO
                 -> Tracer IO String
                 -> ChainDB IO blk (Header blk)
                 -> IO ()
      watchChain registry tracer chainDB = onEachChange
          registry fingerprint initFingerprint
          (ChainDB.getCurrentChain chainDB) (const logFullChain)
        where
          initFingerprint  = (genesisPoint, genesisPoint)
          fingerprint frag = (AF.headPoint frag, AF.anchorPoint frag)
          logFullChain = do
            chain <- ChainDB.toChain chainDB
            traceWith tracer $
              "Updated chain: " <> condense (Chain.toOldestFirst chain)

      encodePoint' ::  Point blk -> Encoding
      encodePoint' =
          Block.encodePoint $ Block.encodeChainHash demoEncodeHeaderHash

      decodePoint' :: forall s. Decoder s (Point blk)
      decodePoint' =
          Block.decodePoint $ Block.decodeChainHash demoDecodeHeaderHash


removeStaleLocalSocket :: FilePath -> IO ()
removeStaleLocalSocket socketPath =
    removeFile socketPath
      `catch` \e ->
        if isDoesNotExistError e
          then return ()
          else throwIO e

