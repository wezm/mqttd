module Main where

import           Control.Monad            (void)
import           Control.Monad.Catch      (MonadMask (..))
import           Control.Monad.Logger     (LogLevel (..), MonadLogger (..), filterLogger, logInfoN, runStderrLoggingT)
import           Data.Conduit.Network     (runTCPServer, serverSettings)
import           Data.Conduit.Network.TLS (runGeneralTCPServerTLS, tlsConfig)
import           Data.Maybe               (fromMaybe)
import qualified Network.WebSockets       as WS
import           UnliftIO                 (MonadUnliftIO (..), async, waitAnyCancel)

import           MQTTD
import           MQTTD.Conduit
import           MQTTD.Config
import           MQTTD.Util

runListener :: (MonadUnliftIO m, MonadLogger m, MonadFail m, MonadMask m) => Listener -> MQTTD m ()
runListener (MQTTListener a p _) = do
  logInfoN ("Starting mqtt service on " <> tshow a <> ":" <> tshow p)
  withRunInIO $ \unl -> runTCPServer (serverSettings p a) (unl . tcpApp)
runListener (WSListener a p _) = do
  logInfoN ("Starting websocket service on " <> tshow a <> ":" <> tshow p)
  withRunInIO $ \unl -> WS.runServer a p (unl . webSocketsApp)
runListener (MQTTSListener a p c k _) = do
  logInfoN ("Starting mqtts service on " <> tshow a <> ":" <> tshow p)
  withRunInIO $ \unl -> runGeneralTCPServerTLS (tlsConfig a p c k) (unl . tcpApp)

main :: IO ()
main = do
  conf@Config{..} <- parseConfFile "mqttd.conf"

  let baseAuth = Authorizer{
        _authAnon = fromMaybe False (_optAllowAnonymous _confDefaults),
        _authUsers = mempty
        }

  e <- newEnv baseAuth
  runStderrLoggingT . logfilt conf . runIO e $ do
    sc <- async sessionCleanup
    pc <- async persistenceCleanup

    ls <- traverse (async . runListener) _confListeners

    void $ waitAnyCancel (sc:pc:ls)

      where
        logfilt Config{..} = filterLogger (\_ -> flip (if _confDebug then (>=) else (>)) LevelDebug)
