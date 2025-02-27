module Scheduler where

import           Control.Concurrent.STM (TVar, check, modifyTVar', newTVarIO, orElse, readTVar, registerDelay,
                                         writeTVar)
import           Control.Monad          (forever)
import           Control.Monad.IO.Class (MonadIO (..))
import           Control.Monad.Logger   (MonadLogger (..))
import           Data.Map.Strict        (Map)
import qualified Data.Map.Strict        as Map
import           Data.Maybe             (fromMaybe)
import           Data.Time.Clock        (NominalDiffTime, UTCTime (..), diffUTCTime, getCurrentTime)
import           UnliftIO               (atomically)

import           MQTTD.Logging
import           MQTTD.Stats
import           MQTTD.Util

-- This bit is just about managing a schedule of tasks.

type TimedQueue a = Map UTCTime [a]

add :: Ord a => UTCTime -> a -> TimedQueue a -> TimedQueue a
add k v = Map.insertWith (<>) k [v]

ready :: UTCTime -> TimedQueue a -> ([a], TimedQueue a)
ready now tq =
  let (rm, mm, q) = Map.splitLookup now tq in
    (concat (Map.elems rm) <> fromMaybe [] mm, q)

next :: TimedQueue a -> Maybe UTCTime
next = fmap fst . Map.lookupMin

-- The actual queue machination is below.

newtype QueueRunner a = QueueRunner {
  _tq  :: TVar (TimedQueue a)
  }

newRunner :: MonadIO m => m (QueueRunner a)
newRunner = QueueRunner <$> liftIO (newTVarIO mempty)

enqueue :: (HasStats m, Ord a, MonadIO m) => UTCTime -> a -> QueueRunner a -> m ()
enqueue t a QueueRunner{_tq} = statStore >>= \ss -> atomically $ do
  incrementStatSTM StatsActionQueued 1 ss
  modifyTVar' _tq (add t a)

-- | Run forever.
run :: (HasStats m, MonadLogger m, MonadIO m) => (a -> m ()) -> QueueRunner a -> m ()
run action = forever . runOnce action

-- | Block until an item might be ready and then run (and remove) all
-- ready items.  This will sometimes run 0 items.  It shouldn't ever
-- run any items that are scheduled for the future, and it shouldn't
-- forget any items that are ready.
runOnce :: (HasStats m, MonadLogger m, MonadIO m) => (a -> m ()) -> QueueRunner a -> m ()
runOnce action QueueRunner{..} = block >> go
  where
    block = liftIO $ do
      now <- getCurrentTime
      mnext <- atomically (next <$> readTVar _tq)
      timedOut <- case diffTimeToMicros . (`diffUTCTime` now) <$> mnext of
                    Nothing -> newTVarIO False
                    Just d  -> registerDelay d
      atomically $ (check =<< readTVar timedOut) `orElse` (check =<< ((/= mnext) . next <$> readTVar _tq))

    go = do
      now <- liftIO getCurrentTime
      todo <- atomically $ do
        (todo, nq) <- ready now <$> readTVar _tq
        writeTVar _tq nq
        pure todo
      logDbgL ["Running ", (tshow . length) todo, " actions"]
      incrementStat StatsActionExecuted (length todo)
      mapM_ action todo

-- A couple utilities

diffTimeToMicros :: NominalDiffTime -> Int
diffTimeToMicros dt = let (s, f) = properFraction dt
                          (μ, _) = properFraction (f * 1000000) in
                        s * 1000000 + μ
