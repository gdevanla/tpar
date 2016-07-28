{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveGeneric #-}

module TPar.SubPubStream
    ( SubPubSource
    , fromProducer
    , subscribe
      -- * Internal
    , produceTChan
    ) where

import Control.Monad.Catch
import Control.Monad (void)
import qualified Data.Set as S
import qualified Data.Map.Strict as M
import GHC.Generics (Generic)
import Data.Binary

import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Control.Concurrent.STM
import Pipes

data SubPubSource a r = SubPubSource (SendPort (SendPort (DataMsg a r), SendPort ()))

-- | A process pushing data from the broadcast channel to a sink.
type PusherProcess = ProcessId

data DataMsg a r = More a
                 | Done r
                 | Failed ProcessId DiedReason
                 deriving (Show, Generic)
instance (Binary a, Binary r) => Binary (DataMsg a r)

-- | Create a new 'SubPubSource' being asynchronously fed by the given
-- 'Producer'. Exceptions thrown by the 'Producer' will be thrown to
-- subscribers.
fromProducer :: forall a r. (Serializable a, Serializable r)
             => Producer a Process r -> Process (SubPubSource a r)
fromProducer prod0 = do
    dataQueue <- liftIO $ atomically $ newTBQueue 10
    (subReqSP, subReqRP) <- newChan
    feeder <- spawnLocal $ feedChan dataQueue prod0
    void $ spawnLocal $ do
        feederRef <- monitor feeder
        loop feederRef subReqRP dataQueue M.empty
    return $ SubPubSource subReqSP
  where
    -- Feed data from Producer into TChan
    feedChan :: TBQueue (DataMsg a r)
             -> Producer a Process r
             -> Process ()
    feedChan queue = go
      where
        go prod = do
            mx <- handleAll (pure . Left) (fmap Right $ next prod)
            case mx of
              Left exc -> do
                  pid <- getSelfPid
                  liftIO $ atomically $ writeTBQueue queue (Failed pid $ DiedException $ show exc)

              Right (Left r) -> do
                  say "feedChan:finishing"
                  liftIO $ atomically $ writeTBQueue queue (Done r)
                  say "feedChan:finished"

              Right (Right (x, prod')) -> do
                  say "feedChan:fed"
                  liftIO $ atomically $ writeTBQueue queue (More x)
                  go prod'

    -- Accept requests for subscriptions and sends data downstream
    loop :: MonitorRef  -- ^ on the feeder
         -> ReceivePort (SendPort (DataMsg a r), SendPort ())
             -- ^ where we take subscription requests
         -> TBQueue (DataMsg a r)
             -- ^ data from feeder
         -> M.Map MonitorRef (SendPort (DataMsg a r))
             -- ^ active subscribers
         -> Process ()
    loop feederRef subReqRP dataQueue subscribers = do
        say "loop:preMatch"
        receiveWait
            [ -- handle death of a subscriber
              matchIf (\(ProcessMonitorNotification mref _ _) -> mref `M.member` subscribers)
              $ \(ProcessMonitorNotification mref pid reason) -> do
                  say "loop:subDied"
                  loop feederRef subReqRP dataQueue (M.delete mref subscribers)

              -- subscription request
            , matchChan subReqRP $ \(sink, confirm) -> do
                  say "loop:subReq"
                  sinkRef <- monitorPort sink
                  sendChan confirm ()
                  loop feederRef subReqRP dataQueue (M.insert sinkRef sink subscribers)

              -- data for subscribers
            , matchSTM (readTBQueue dataQueue) $ \msg -> do
                  say "loop:data"
                  sendToSubscribers msg
                  case msg of
                    More _ ->
                      loop feederRef subReqRP dataQueue subscribers
                    _ -> return ()

              -- handle death of the feeder
            , matchIf (\(ProcessMonitorNotification mref _ _) -> mref == feederRef)
              $ \(ProcessMonitorNotification _ pid reason) -> do
                  say "loop:feederDied"
                  sendToSubscribers $ Failed pid reason

            ]
      where
        sendToSubscribers msg = mapM_ (`sendChan` msg) subscribers

-- | An exception indicating that the upstream 'Producer' feeding a
-- 'SubPubSource' failed.
data SubPubProducerFailed = SubPubProducerFailed ProcessId DiedReason
                          deriving (Show)
instance Exception SubPubProducerFailed

produceTChan :: TChan (Either r a) -> Producer a Process r
produceTChan chan = go
  where
    go = do
        lift $ say "produceTChan:waiting"
        mx <- liftIO $ atomically $ readTChan chan
        case mx of
          Right x -> lift (say "produceTChan:fed") >> yield x >> go
          Left r  -> lift (say "produceTChan:done") >> return r

-- | Subscribe to a 'SubPubSource'. Exceptions thrown by the 'Producer' feeding
-- the 'SubPubSource' will be thrown by the returned 'Producer'. Will return
-- 'Nothing' if the 'SubPubSource' terminated before we were able to subscribe.
subscribe :: forall a r. (Serializable a, Serializable r)
          => SubPubSource a r -> Process (Maybe (Producer a Process r))
subscribe (SubPubSource reqSP) = do
    -- We provide a channel to confirm that we have actually been subscribed
    -- so that we can safely link during negotiation.
    say "subscribing"
    mref <- monitorPort reqSP
    (confirmSp, confirmRp) <- newChan
    (dataSp, dataRp) <- newChan
    sendChan reqSP (dataSp, confirmSp)
    say "subscribe: waiting for confirmation"
    let go = do
            msg <- lift $ receiveWait
                [ matchChan dataRp return
                , matchIf (\(PortMonitorNotification mref' _ _) -> mref == mref')
                  $ const $ fail "subscribe: it died"
                ]
            case msg of
              Failed pid reason -> lift $ throwM $ SubPubProducerFailed pid reason
              Done r -> return r
              More x -> yield x >> go

    receiveWait
        [ matchChan confirmRp $ \() -> return $ Just go
        , matchIf (\(PortMonitorNotification mref' _ _) -> mref == mref') (pure $ pure Nothing)
        ]
