{-# LANGUAGE BangPatterns #-}

module Pygmalion.Database.Manager
( runDatabaseManager
, ensureDB
, DBRequest (..)
, DBChan
) where

import Control.Applicative
import Control.Monad
import Data.Time.Clock

import Control.Concurrent.Chan.Len
import Pygmalion.Core
import Pygmalion.Database.IO
import Pygmalion.Log

data DBRequest = DBUpdateCommandInfo CommandInfo
               | DBUpdateDef DefUpdate
               | DBUpdateOverride Override
               | DBUpdateRef ReferenceUpdate
               | DBUpdateInclusion Inclusion
               | DBInsertFileAndCheck SourceFile (Response Bool)
               | DBResetMetadata SourceFile
               | DBGetCommandInfo SourceFile (Response (Maybe CommandInfo))
               | DBGetSimilarCommandInfo SourceFile (Response (Maybe CommandInfo))
               | DBGetDefinition USR (Response (Maybe DefInfo))
               | DBGetIncluders SourceFile (Response [CommandInfo])
               | DBGetCallers USR (Response [Invocation])
               | DBGetCallees USR (Response [DefInfo])
               | DBGetBases USR (Response [DefInfo])
               | DBGetOverrides USR (Response [DefInfo])
               | DBGetRefs USR (Response [SourceReference])
               | DBGetReferenced SourceLocation (Response [SourceReferenced])
               | DBShutdown
               deriving (Show)
type DBChan = LenChan DBRequest

runDatabaseManager :: DBChan -> DBChan -> IO ()
runDatabaseManager chan queryChan = do
    start <- getCurrentTime
    withDB (go 0 start)
  where
    go :: Int -> UTCTime -> DBHandle -> IO ()
    go 1000 !start !h = do 
      stop <- getCurrentTime
      logInfo $ "Handled 1000 records in " ++ (show $ stop `diffUTCTime` start)
      newStart <- getCurrentTime
      go 0 newStart h
    go !n !s !h = {-# SCC "databaseThread" #-}
           do (!tookFirst, !newCount, !req) <- readEitherChan n queryChan chan
              logDebug $ "Database request: " ++ (show req)
              logDebug $ if tookFirst then "Query channel now has " ++ (show newCount) ++ " queries waiting"
                                      else "Database channel now has " ++ (show newCount) ++ " requests waiting"
              case req of
                DBUpdateCommandInfo !ci       -> doUpdateCommandInfo h ci >> go (n+1) s h
                DBUpdateDef !di               -> doUpdateDef h di >> go (n+1) s h
                DBUpdateOverride !ov          -> doUpdateOverride h ov >> go (n+1) s h
                DBUpdateRef !rf               -> doUpdateRef h rf >> go (n+1) s h
                DBInsertFileAndCheck !sf !v   -> doInsertFileAndCheck h sf v >> go (n+1) s h
                DBUpdateInclusion !ic         -> doUpdateInclusion h ic >> go (n+1) s h
                DBResetMetadata !sf           -> doResetMetadata h sf >> go (n+1) s h
                DBGetCommandInfo !f !v        -> doGetCommandInfo h f v >> go (n+1) s h
                DBGetSimilarCommandInfo !f !v -> doGetSimilarCommandInfo h f v >> go (n+1) s h
                DBGetDefinition !u !v         -> doGetDefinition h u v >> go (n+1) s h
                DBGetIncluders !sf !v         -> doGetIncluders h sf v >> go (n+1) s h
                DBGetCallers !usr !v          -> doGetCallers h usr v >> go (n+1) s h
                DBGetCallees !usr !v          -> doGetCallees h usr v >> go (n+1) s h
                DBGetBases !usr !v            -> doGetBases h usr v >> go (n+1) s h
                DBGetOverrides !usr !v        -> doGetOverrides h usr v >> go (n+1) s h
                DBGetRefs !usr !v             -> doGetRefs h usr v >> go (n+1) s h
                DBGetReferenced !sl !v        -> doGetReferenced h sl v >> go (n+1) s h
                DBShutdown                    -> logInfo "Shutting down DB thread"

readEitherChan :: Int -> DBChan -> DBChan -> IO (Bool, Int, DBRequest)
readEitherChan n queryChan chan
  | n `rem` 10 == 0 = readLenChanPreferFirst queryChan chan
  | otherwise       = readLenChanPreferFirst chan queryChan

doUpdateCommandInfo :: DBHandle -> CommandInfo -> IO ()
doUpdateCommandInfo h ci = withTransaction h $ do
  logDebug $ "Updating database with command: " ++ (show . ciSourceFile $ ci)
  updateSourceFile h ci

doUpdateDef :: DBHandle -> DefUpdate -> IO ()
doUpdateDef h du = withTransaction h $ do
  logDebug $ "Updating database with def: " ++ (show . diuUSR $ du)
  updateDef h du

doUpdateOverride :: DBHandle -> Override -> IO ()
doUpdateOverride h ov = withTransaction h $ do
  logDebug $ "Updating database with override: " ++ (show ov)
  updateOverride h ov

doUpdateRef :: DBHandle -> ReferenceUpdate -> IO ()
doUpdateRef h ru = withTransaction h $ do
  logDebug $ "Updating database with reference: " ++ (show ru)
  updateReference h ru

doUpdateInclusion :: DBHandle -> Inclusion -> IO ()
doUpdateInclusion h ic = withTransaction h $ do
    logDebug $ "Updating database with inclusion: " ++ (show ic)
    updateInclusion h ic

doInsertFileAndCheck :: DBHandle -> SourceFile -> Response Bool -> IO ()
doInsertFileAndCheck h f v = do
  logDebug $ "Inserting file and checking for " ++ (show f)
  sendResponse v =<< insertFileAndCheck h f

doResetMetadata :: DBHandle -> SourceFile -> IO ()
doResetMetadata h sf = withTransaction h $ do
  logDebug $ "Resetting metadata for file: " ++ (show sf)
  resetMetadata h sf

doGetCommandInfo :: DBHandle -> SourceFile -> Response (Maybe CommandInfo) -> IO ()
doGetCommandInfo h f v = do
  logDebug $ "Getting CommandInfo for " ++ (show f)
  sendResponse v =<< getCommandInfo h f

doGetSimilarCommandInfo :: DBHandle -> SourceFile -> Response (Maybe CommandInfo) -> IO ()
doGetSimilarCommandInfo h f v = do
  logDebug $ "Getting similar CommandInfo for " ++ (show f)
  ci <- liftM2 (<|>) (getCommandInfo h f) (getSimilarCommandInfo h f)
  sendResponse v ci

doGetDefinition :: DBHandle -> USR -> Response (Maybe DefInfo) -> IO ()
doGetDefinition h usr v = do
  logDebug $ "Getting DefInfo for " ++ (show usr)
  sendResponse v =<< getDef h usr

doGetIncluders :: DBHandle -> SourceFile -> Response [CommandInfo] -> IO ()
doGetIncluders h sf v = do
  logDebug $ "Getting includers for " ++ (show sf)
  sendResponse v =<< getIncluders h sf

doGetCallers :: DBHandle -> USR -> Response [Invocation] -> IO ()
doGetCallers h usr v = do
  logDebug $ "Getting callers for " ++ (show usr)
  sendResponse v =<< getCallers h usr

doGetCallees :: DBHandle -> USR -> Response [DefInfo] -> IO ()
doGetCallees h usr v = do
  logDebug $ "Getting callees for " ++ (show usr)
  sendResponse v =<< getCallees h usr

doGetBases :: DBHandle -> USR -> Response [DefInfo] -> IO ()
doGetBases h usr v = do
  logDebug $ "Getting bases for " ++ (show usr)
  sendResponse v =<< getOverrided h usr

doGetOverrides :: DBHandle -> USR -> Response [DefInfo] -> IO ()
doGetOverrides h usr v = do
  logDebug $ "Getting overrides for " ++ (show usr)
  sendResponse v =<< getOverriders h usr

doGetRefs :: DBHandle -> USR -> Response [SourceReference] -> IO ()
doGetRefs h usr v = do
  logDebug $ "Getting refs for " ++ (show usr)
  sendResponse v =<< getReferences h usr

doGetReferenced :: DBHandle -> SourceLocation -> Response [SourceReferenced] -> IO ()
doGetReferenced h sl v = do
  logDebug $ "Getting referenced for " ++ (show sl)
  sendResponse v =<< getReferenced h sl
