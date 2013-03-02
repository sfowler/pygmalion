module Pygmalion.Database
( ensureDB
, withDB
, updateRecord
, getAllRecords
, DBHandle
, dbFilename
) where

import Control.Concurrent
import Control.Exception(bracket, catch, SomeException)
import Control.Monad
import Data.List
import Data.Int
import Database.SQLite

import Pygmalion.Core

-- Configuration.
dbFilename :: String
dbFilename = ".pygmalion.sqlite"

-- Schema for the database.
dbInt, dbString, dbPath :: SQLType
dbInt = SQLInt NORMAL True True
dbString = SQLVarChar 2048
dbPath = SQLVarChar 2048

dbToolName :: String
dbToolName = "pygmalion"

dbMajorVersion, dbMinorVersion :: Int64
dbMajorVersion = 0
dbMinorVersion = 1

metadataTable :: SQLTable
metadataTable = Table "Metadata"
                [
                  Column "Tool" dbString [Unique],
                  Column "MajorVersion" dbInt [],
                  Column "MinorVersion" dbInt []
                ] []

execGetDBVersion :: SQLiteResult a => SQLiteHandle -> IO (Either String [[Row a]])
execGetDBVersion h = execParamStatement h sql params
  where sql = "select MajorVersion, MinorVersion from Metadata " ++
              "where Tool = :tool"
        params = [(":tool", Text dbToolName)]

execSetDBVersion :: SQLiteHandle -> IO (Maybe String)
execSetDBVersion h = execParamStatement_ h sql params
  where sql = "insert into Metadata (Tool, MajorVersion, MinorVersion) " ++
              "values (:tool, :major, :minor)"
        params = [(":tool",  Text dbToolName),
                  (":major", Int dbMajorVersion),
                  (":minor", Int dbMinorVersion)]

sourceFileTable :: SQLTable
sourceFileTable = Table "SourceFiles"
                  [
                    Column "File" dbPath [Unique],
                    Column "WorkingDirectory" dbPath [],
                    Column "Command" dbString [],
                    Column "LastBuilt" dbInt []
                  ] []

execUpdateSourceFile :: SQLiteHandle -> CommandInfo -> IO (Maybe String)
execUpdateSourceFile h (CommandInfo file wd cmd time) =
    execParamStatement_ h sql params
  where sql =  "replace into SourceFiles "
            ++ "(File, WorkingDirectory, Command, LastBuilt) "
            ++ "values (:file, :wd, :cmd, :time)"
        params = [(":file", Text file),
                  (":wd",   Text wd),
                  (":cmd",  Text $ intercalate " " cmd),
                  (":time", Int time)]

execGetAllSourceFiles :: SQLiteResult a => SQLiteHandle
                                        -> IO (Either String [[Row a]])
execGetAllSourceFiles h = execStatement h sql
  where sql =  "select File as file, "
            ++ "WorkingDirectory as directory, "
            ++ "Command as command "
            ++ "from SourceFiles"

schema :: [SQLTable]
schema = [metadataTable, sourceFileTable]

-- Debugging functions.
withCatch :: String -> IO a -> IO a
withCatch lbl f = Control.Exception.catch f printAndRethrow
  where printAndRethrow :: SomeException -> IO a
        printAndRethrow e = error $ lbl ++ ": " ++ (show e)

-- Database manipulation functions.
type DBHandle = SQLiteHandle

ensureDB :: FilePath -> IO ()
ensureDB db = withDB db (const . return $ ())

withDB :: FilePath -> (DBHandle -> IO a) -> IO a
withDB db f = bracket (withCatch "open" (openDB db)) closeDB f

openDB :: FilePath -> IO DBHandle
openDB db = do
  handle <- (retry 100 500 $ openConnection db)
  ensureSchema handle
  return handle

closeDB :: DBHandle -> IO ()
closeDB = closeConnection

updateRecord :: DBHandle -> CommandInfo -> IO ()
updateRecord h ci = withCatch "updateRecord" $ execUpdateSourceFile h ci >>= ensureNothing

getAllRecords :: DBHandle -> IO [Row Value]
getAllRecords h = withCatch "getAllRecords" $ execGetAllSourceFiles h >>= ensureRight >>= return . concat

-- Checks that the database has the correct schema and sets it up if needed.
ensureSchema :: DBHandle -> IO ()
ensureSchema h = forM_ schema $ \table ->
      defineTableOpt h True table
  >>= ensureNothing
  >>  ensureVersion h

ensureVersion :: DBHandle -> IO ()
ensureVersion h = execGetDBVersion h >>= ensureRight >>= checkVersion
  where
    checkVersion [[[("MajorVersion", Int major),
                    ("MinorVersion", Int minor)]]]
                 | (major, minor) == (dbMajorVersion, dbMinorVersion)
                 = return ()
    checkVersion [[]] = execSetDBVersion h >>= ensureNothing
    checkVersion rs = throwDBVersionError rs

throwDBVersionError :: Show a => [[Row a]] -> IO ()
throwDBVersionError rs = error $ "Database version must be "
                             ++ (show dbMajorVersion) ++ "."
                             ++ (show dbMinorVersion) ++ " but I got "
                             ++ (show rs)

-- Utility functions.
ensureNothing :: Maybe String -> IO ()
ensureNothing (Just s) = error s
ensureNothing _        = return ()

ensureRight :: Either String a -> IO a
ensureRight (Left s)  = error s
ensureRight (Right a) = return a

retry :: Int -> Int -> IO a -> IO a
retry 0 _ action     = action
retry n delay action = Control.Exception.catch action (delayAndRetry action)
  where delayAndRetry :: IO a -> SomeException -> IO a
        delayAndRetry f _ = (threadDelay delay) >> retry (n - 1) delay f
