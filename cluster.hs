#!/usr/bin/env stack
-- stack --install-ghc runghc --package turtle

-- OR, to pre-compile this:
-- $ stack ghc -- -O2 -threaded cluster.hs

{-# LANGUAGE ApplicativeDo       #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}

import           Control.Concurrent.Async (Async, forConcurrently,
                                           mapConcurrently)
import           Control.Concurrent.MVar  (isEmptyMVar, newEmptyMVar, putMVar,
                                           takeMVar)
import qualified Control.Foldl            as Fold
import           Control.Monad.Managed    (MonadManaged)
import           Data.Aeson
import           Data.Foldable            (traverse_)
import           Data.Functor             (($>))
import           Data.Maybe               (fromMaybe)
import           Data.Text                (isInfixOf)
import qualified Data.Text.IO             as T
import           Data.Text.Lazy           (toStrict)
import           Data.Text.Lazy.Encoding  (decodeUtf8)
import           Prelude                  hiding (FilePath)
import           System.IO                (BufferMode (..), hClose,
                                           hSetBuffering, hFlush)
import           Turtle

main :: IO ()
main = sh $ setupNodes [GethId 1, GethId 2, GethId 3] >>= runNodes

--

data GethId = GethId { gId :: Int }
  deriving (Show, Eq)

data EnodeId = EnodeId { enodeId :: Text }
  deriving (Show, Eq)

instance ToJSON EnodeId where
  toJSON (EnodeId eid) = String eid

data Geth =
  Geth { gethId      :: GethId
       , gethEnodeId :: EnodeId
       }
  deriving (Show, Eq)

gethBinary :: GethId -> Text
gethBinary gid = mkCommand (dataDir gid)
                           (httpPort gid)
                           (rpcPort gid)
                           networkId
  where
    mkCommand = format $ "geth --datadir "%fp       %
                             " --port "%d           %
                             " --rpcport "%d        %
                             " --networkid "%d      %
                             " --nodiscover"        %
                             " --maxpeers 10"       %
                             " --rpc"               %
                             " --rpccorsdomain '*'" %
                             " --rpcaddr localhost"

gethCommand :: Text -> GethId -> Text
gethCommand cmd gid = format (s % " " % s) (gethBinary gid) cmd

-- TODO: all of these could come out of a reader environment

dataDirRoot :: FilePath
dataDirRoot = "gdata"

password :: Text
password = "abcd"

networkId :: Int
networkId = 1418

genesisJson :: FilePath
genesisJson = "genesis.json"

httpPort :: GethId -> Int
httpPort (GethId gid) = 30400 + gid

rpcPort :: GethId -> Int
rpcPort (GethId gid) = 40400 + gid

-- defaultVerbosity :: Maybe Int
-- defaultVerbosity = Nothing


dataDir :: GethId -> FilePath
dataDir geth = dataDirRoot </> fromText nodeName
  where
    nodeName = format ("geth"%d) (gId geth)

wipeDataDirs :: MonadIO io => io ()
wipeDataDirs = rmtree dataDirRoot

initNode :: MonadIO io => GethId -> io ()
initNode geth = shells initCommand empty
  where
    initCommand :: Text
    initCommand = gethCommand (format ("init "%fp) genesisJson) geth

createAccount :: MonadIO io => Text -> GethId -> io ()
createAccount pw gid = shells createCommand inputPasswordTwice
  where
    createCommand :: Text
    createCommand = gethCommand "account new" gid

    inputPasswordTwice :: Shell Text
    inputPasswordTwice = return pw -- "Passphrase:"
                     <|> return pw -- "Repeat passphrase:"

fileContaining :: Shell Text -> Managed FilePath
fileContaining contents = do
  dir <- using $ mktempdir "/tmp" "geth"
  (path, handle) <- using $ mktemp dir "geth"
  liftIO $ outhandle handle contents
  liftIO $ hClose handle
  return path

getEnodeId :: MonadIO io => GethId -> io EnodeId
getEnodeId gid = EnodeId . forceMaybe <$> fold enodeIdShell Fold.head
  where
    jsCommand jsPath = gethCommand (format ("js "%fp) jsPath) gid
    jsPayload = return "console.log(admin.nodeInfo.enode)"
    forceMaybe = fromMaybe $ error "unable to extract enode ID"

    enodeIdShell :: Shell Text
    enodeIdShell = sed (begins "enode") $ do
      jsPath <- using $ fileContaining jsPayload
      inshell (jsCommand jsPath) empty

-- > allSiblings [1,2,3]
-- [(1,[2,3]),(2,[1,3]),(3,[1,2])]
--
allSiblings :: (Alternative m, Monad m, Eq a) => m a -> m (a, m a)
allSiblings as = (\a -> (a, sibs a)) <$> as
  where
    sibs me = do
      sib <- as
      guard $ me /= sib
      pure sib

writeStaticNodes :: (MonadIO io) => [Geth] -> Geth -> io ()
writeStaticNodes sibs geth = output jsonPath contents
  where
    jsonPath = dataDir (gethId geth) </> "static-nodes.json"
    contents = return $ toStrict . decodeUtf8 . encode $ gethEnodeId <$> sibs

mkGeth :: MonadIO io => GethId -> io Geth
mkGeth gid = Geth gid <$> getEnodeId gid

setupNodes :: MonadIO io => [GethId] -> io [Geth]
setupNodes gids = do
  wipeDataDirs

  void $ liftIO $ forConcurrently gids $ \gid -> do
    initNode gid
    createAccount password gid

  geths <- liftIO $ mapConcurrently mkGeth gids

  liftIO $ forConcurrently (allSiblings geths) $ \(geth, sibs) -> do
    writeStaticNodes sibs geth
    pure geth

nodeShell :: Geth -> Shell Text
nodeShell geth = do
  line <- inshellWithErr (gethCommand "" (gethId geth)) empty
  case line of
    Left txt  -> return txt
    Right txt -> return txt

data NodeReady = NodeReady -- online, and ready for us to start raft
data NodeTerminated = NodeTerminated

runNode :: forall m. MonadManaged m
        => Geth
        -> m (Async NodeReady, Async NodeTerminated)
runNode geth = do
  mvar <- liftIO newEmptyMVar

  let started :: m (Async NodeReady)
      started = fork $ do
                  _ <- takeMVar mvar
                  return NodeReady

      outputPath :: FilePath
      outputPath = fromText $ format ("geth"%d%".out") (gId $ gethId geth)

      terminated :: m (Async NodeTerminated)
      terminated = fmap ($> NodeTerminated) $
        using $ fork $ runManaged $ do
          handle <- using (writeonly outputPath)
          liftIO $ hSetBuffering handle LineBuffering

          foldIO (nodeShell geth) $ Fold.mapM_ $ \line -> do
            liftIO $ T.hPutStrLn handle line
            guard =<< isEmptyMVar mvar
            when ("IPC endpoint opened:" `isInfixOf` line) $
              putMVar mvar NodeReady

  (,) <$> started <*> terminated

startRaft :: MonadIO io => Geth -> io ()
startRaft geth = shells startCommand empty
  where
    startCommand =
      gethCommand (format ("--exec 'raft.startNode();' attach "%s) ipcEndpoint)
                  (gethId geth)

    ipcPath = dataDir (gethId geth) </> "geth.ipc"
    ipcEndpoint = format ("ipc:"%fp) ipcPath

awaitAll :: Traversable t => t (Async a) -> IO ()
awaitAll = traverse_ wait

runNodes :: MonadManaged m => [Geth] -> m ()
runNodes geths = do
  (readyAsyncs, terminatedAsyncs) <- unzip <$> traverse runNode geths
  liftIO $ do
    awaitAll readyAsyncs
    traverse_ startRaft geths
    awaitAll terminatedAsyncs

--
--


-- TODO: use this
--
-- type IdProducer = MonadState GethId
--
-- produceId :: IdProducer m => m GethId
-- produceId = do
--   id@(GethId i) <- S.get
--   S.put (GethId (i + 1))
--   return id


-- TODO: use this
--
-- postTx :: MonadIO io => Int -> io ()
-- postTx gethId =
--   let port = 40400 + gethId
--       route = format ("http://localhost:"%d) show port
--
--       t :: Text -> Text
--       t = id
--
--       body :: Value
--       body = object
--         [ "id" .= (1 :: Int)
--         , "jsonrpc" .= t "2.0"
--         , "method" .= t "eth_sendTransaction"
--         , "params" .= object
--           [ "from" .= t "joel"
--           , "to" .= t "jpm"
--           ]
--         ]
--   in liftIO $ post route body >> return ()
