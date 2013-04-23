module Pygmalion.Database.Manager
( runDatabaseManager
, ensureDB
, DBRequest (..)
, DBChan
) where

import Control.Applicative
import Control.Concurrent
import Control.Monad
import Control.Monad.Trans
import Data.Time.Clock
import Data.Time.Clock.POSIX

import Control.Concurrent.Chan.Len
import Pygmalion.Core
import Pygmalion.Database.IO
import Pygmalion.Log

data DBRequest = DBUpdateCommandInfo CommandInfo
               | DBUpdateDefInfo DefInfo
               | DBUpdateOverride Override
               | DBUpdateCaller Caller
               | DBUpdateRef Reference
               | DBUpdateInclusion CommandInfo Inclusion
               | DBGetCommandInfo SourceFile (MVar (Maybe CommandInfo))
               | DBGetSimilarCommandInfo SourceFile (MVar (Maybe CommandInfo))
               | DBGetDefinition USR (MVar (Maybe DefInfo))
               | DBGetIncluders SourceFile (MVar [CommandInfo])
               | DBGetCallers USR (MVar [Invocation])
               | DBGetCallees USR (MVar [DefInfo])
               | DBGetRefs USR (MVar [SourceRange])
               | DBGetReferenced SourceLocation (MVar [DefInfo])
               | DBShutdown
type DBChan = LenChan DBRequest

runDatabaseManager :: DBChan -> DBChan -> IO ()
runDatabaseManager chan queryChan = do
    start <- getCurrentTime
    withDB (go 0 start)
  where
    go :: Int -> UTCTime -> DBHandle -> IO ()
    go 1000 start h = do 
      stop <- getCurrentTime
      logInfo $ "Handled 1000 records in " ++ (show $ stop `diffUTCTime` start)
      newStart <- getCurrentTime
      go 0 newStart h
    go n s h = {-# SCC "databaseThread" #-}
           do (tookFirst, newCount, req) <- readLenChanPreferFirst queryChan chan
              logDebug $ if tookFirst then "Query channel now has " ++ (show newCount) ++ " queries waiting"
                                      else "Database channel now has " ++ (show newCount) ++ " requests waiting"
              case req of
                DBUpdateCommandInfo ci      -> doUpdateCommandInfo h ci >> go (n+1) s h
                DBUpdateDefInfo di          -> doUpdateDefInfo h di >> go (n+1) s h
                DBUpdateOverride ov         -> doUpdateOverride h ov >> go (n+1) s h
                DBUpdateCaller cr           -> doUpdateCaller h cr >> go (n+1) s h
                DBUpdateRef rf              -> doUpdateRef h rf >> go (n+1) s h
                DBUpdateInclusion ci ic     -> doUpdateInclusion h ci ic >> go (n+1) s h
                DBGetCommandInfo f v        -> doGetCommandInfo h f v >> go (n+1) s h
                DBGetSimilarCommandInfo f v -> doGetSimilarCommandInfo h f v >> go (n+1) s h
                DBGetDefinition u v         -> doGetDefinition h u v >> go (n+1) s h
                DBGetIncluders sf v         -> doGetIncluders h sf v >> go (n+1) s h
                DBGetCallers usr v          -> doGetCallers h usr v >> go (n+1) s h
                DBGetCallees usr v          -> doGetCallees h usr v >> go (n+1) s h
                DBGetRefs usr v             -> doGetRefs h usr v >> go (n+1) s h
                DBGetReferenced sl v        -> doGetReferenced h sl v >> go (n+1) s h
                DBShutdown                  -> logInfo "Shutting down DB thread"

doUpdateCommandInfo :: DBHandle -> CommandInfo -> IO ()
doUpdateCommandInfo h cmd = liftIO $ withTransaction h $ do
  time <- getPOSIXTime
  let ci = cmd { ciLastIndexed = floor time }
  liftIO $ logDebug $ "Updating database with command: " ++ (show . ciSourceFile $ ci)
  updateSourceFile h ci

doUpdateDefInfo :: DBHandle -> DefInfo -> IO ()
doUpdateDefInfo h di = liftIO $ withTransaction h $ do
  liftIO $ logDebug $ "Updating database with def: " ++ (show . diUSR $ di)
  updateDef h di

doUpdateOverride :: DBHandle -> Override -> IO ()
doUpdateOverride h ov = liftIO $ withTransaction h $ do
  liftIO $ logDebug $ "Updating database with override: " ++ (show ov)
  updateOverride h ov

doUpdateCaller :: DBHandle -> Caller -> IO ()
doUpdateCaller h cr = liftIO $ withTransaction h $ do
  liftIO $ logDebug $ "Updating database with caller: " ++ (show cr)
  updateCaller h cr

doUpdateRef :: DBHandle -> Reference -> IO ()
doUpdateRef h rf = liftIO $ withTransaction h $ do
  liftIO $ logDebug $ "Updating database with reference: " ++ (show rf)
  updateReference h rf

doUpdateInclusion :: DBHandle -> CommandInfo -> Inclusion -> IO ()
doUpdateInclusion h cmd ic = liftIO $ withTransaction h $ do
  liftIO $ logDebug $ "Updating database with inclusion: " ++ (show ic)
  time <- getPOSIXTime
  let ci = cmd { ciLastIndexed = floor time, ciSourceFile = icHeaderFile ic }
  updateSourceFile h ci
  updateInclusion h ic

doGetCommandInfo :: DBHandle -> SourceFile -> MVar (Maybe CommandInfo) -> IO ()
doGetCommandInfo h f v = do
  liftIO $ logDebug $ "Getting CommandInfo for " ++ (show f)
  ci <- getCommandInfo h f
  putMVar v $! ci

doGetSimilarCommandInfo :: DBHandle -> SourceFile -> MVar (Maybe CommandInfo) -> IO ()
doGetSimilarCommandInfo h f v = do
  liftIO $ logDebug $ "Getting similar CommandInfo for " ++ (show f)
  ci <- liftM2 (<|>) (getCommandInfo h f) (getSimilarCommandInfo h f)
  putMVar v $! ci

doGetDefinition :: DBHandle -> USR -> MVar (Maybe DefInfo) -> IO ()
doGetDefinition h usr v = do
  liftIO $ logDebug $ "Getting DefInfo for " ++ (show usr)
  def <- getDef h usr
  putMVar v $! def

doGetIncluders :: DBHandle -> SourceFile -> MVar [CommandInfo] -> IO ()
doGetIncluders h sf v = do
  liftIO $ logDebug $ "Getting includers for " ++ (show sf)
  includers <- getIncluders h sf
  putMVar v $! includers

doGetCallers :: DBHandle -> USR -> MVar [Invocation] -> IO ()
doGetCallers h usr v = do
  liftIO $ logDebug $ "Getting callers for " ++ (show usr)
  callers <- getCallers h usr
  putMVar v $! callers

doGetCallees :: DBHandle -> USR -> MVar [DefInfo] -> IO ()
doGetCallees h usr v = do
  liftIO $ logDebug $ "Getting callees for " ++ (show usr)
  callees <- getCallees h usr
  putMVar v $! callees

doGetRefs :: DBHandle -> USR -> MVar [SourceRange] -> IO ()
doGetRefs h usr v = do
  liftIO $ logDebug $ "Getting refs for " ++ (show usr)
  refs <- getReferences h usr
  putMVar v $! refs

doGetReferenced :: DBHandle -> SourceLocation -> MVar [DefInfo] -> IO ()
doGetReferenced h sl v = do
  liftIO $ logDebug $ "Getting referenced for " ++ (show sl)
  refs <- getReferenced h sl
  putMVar v $! refs
