{-# LANGUAGE OverloadedStrings #-}

module Pygmalion.Database
( ensureDB
, withDB
, updateSourceFile
, getAllSourceFiles
, getCommandInfo
, getSimilarCommandInfo
, updateDef
, getDef
, enableTracing
, DBHandle
) where

import Control.Exception(bracket)
import Data.Int
import Data.String
import qualified Data.Text as T
import Database.SQLite.Simple
import Database.SQLite.Simple.ToField (ToField(..))

import Control.Exception.Labeled
import Pygmalion.Core

-- General database manipulation functions. These are thin wrappers around the
-- underlying database implementation that also verify that the database is
-- configured according to the correct schema and enable foreign keys.
type DBHandle = Connection

ensureDB :: IO ()
ensureDB = withDB (const . return $ ())

withDB :: (DBHandle -> IO a) -> IO a
withDB f = bracket (openDB dbFile) closeDB f

openDB :: FilePath -> IO DBHandle
openDB db = labeledCatch "openDB" $ do
  h <- open db
  enableForeignKeyConstraints h
  ensureSchema h
  return h

closeDB :: DBHandle -> IO ()
closeDB = close

enableForeignKeyConstraints :: DBHandle -> IO ()
enableForeignKeyConstraints h = execute_ h "pragma foreign_keys = on"

enableTracing :: DBHandle -> IO ()
enableTracing h = setTrace h (Just $ putStrLn . T.unpack)

-- Schema and operations for the Metadata table.
dbToolName :: String
dbToolName = "pygmalion"

dbMajorVersion, dbMinorVersion :: Int64
dbMajorVersion = 0
dbMinorVersion = 4

defineMetadataTable :: DBHandle -> IO ()
defineMetadataTable h = execute_ h 
  "create table if not exists Metadata(               \
  \ Tool varchar(2048) primary key not null,          \
  \ MajorVersion integer zerofill unsigned not null,  \
  \ MinorVersion integer zerofill unsigned not null)"

getDBVersion :: DBHandle -> IO (Maybe (Int64, Int64))
getDBVersion h = do
    row <- query h sql params
    return $ case row of
              [version] -> Just version
              _         -> Nothing
  where sql = "select MajorVersion, MinorVersion from Metadata \
              \where Tool = ?"
        params = Only dbToolName

setDBVersion :: DBHandle -> IO ()
setDBVersion h = execute h sql params
  where sql = "insert into Metadata (Tool, MajorVersion, MinorVersion) \
              \values (?, ?, ?)"
        params = (dbToolName, dbMajorVersion, dbMinorVersion)

-- Schema and operations for the Files table.
defineFilesTable :: DBHandle -> IO ()
defineFilesTable h = execute_ h sql
  where sql =  "create table if not exists Files(        \
               \ Id integer primary key unique not null, \
               \ Name varchar(2048) unique not null)"

-- Schema and operations for the Paths table.
definePathsTable :: DBHandle -> IO ()
definePathsTable h = execute_ h sql
  where sql =  "create table if not exists Paths(        \
               \ Id integer primary key unique not null, \
               \ Path varchar(2048) unique not null)"

-- Schema and operations for the BuildCommands table.
defineBuildCommandsTable :: DBHandle -> IO ()
defineBuildCommandsTable h = execute_ h sql
  where sql =  "create table if not exists BuildCommands(\
               \ Id integer primary key unique not null, \
               \ Command varchar(2048) unique not null)"

-- Schema and operations for the BuildArgs table.
defineBuildArgsTable :: DBHandle -> IO ()
defineBuildArgsTable h = execute_ h sql
  where sql =  "create table if not exists BuildArgs(    \
               \ Id integer primary key unique not null, \
               \ Args varchar(2048) unique not null)"

-- Schema and operations for the SourceFiles table.
defineSourceFilesTable :: DBHandle -> IO ()
defineSourceFilesTable h = execute_ h sql
  where sql =  "create table if not exists SourceFiles(                  \
               \ File integer not null,                                  \
               \ Path integer not null,                                  \
               \ WorkingDirectory integer not null,                      \
               \ BuildCommand integer not null,                          \
               \ BuildArgs integer not null,                             \
               \ LastBuilt integer zerofill unsigned not null,           \
               \ foreign key(File) references Files(Id),                 \
               \ foreign key(Path) references Paths(Id),                 \
               \ foreign key(WorkingDirectory) references Paths(Id),     \
               \ foreign key(BuildCommand) references BuildCommands(Id), \
               \ foreign key(BuildArgs) references BuildArgs(Id),        \
               \ primary key(File, Path))"

updateSourceFile :: DBHandle -> CommandInfo -> IO ()
updateSourceFile h (CommandInfo (SourceFile sn sp) wd (Command cmd args) t) = do
    execute_ h "begin transaction"
    fileId <- getIdForRow h "Files" "Name" sn
    pathId <- getIdForRow h "Paths" "Path" sp
    wdId <- getIdForRow h "Paths" "Path" wd
    cmdId <- getIdForRow h "BuildCommands" "Command" cmd
    argsId <- getIdForRow h "BuildArgs" "Args" (T.intercalate " " args)
    execute h sql (fileId, pathId, wdId, cmdId, argsId, t)
    execute_ h "commit"
  where
    sql =  "replace into SourceFiles                                           \
           \(File, Path, WorkingDirectory, BuildCommand, BuildArgs, LastBuilt) \
           \values (?, ?, ?, ?, ?, ?)"

getIdForRow :: ToField a => DBHandle -> String -> String -> a -> IO Int64
getIdForRow h table col val = do
  existingId <- query h selectSQL (Only val)
  case existingId of
    (Only i : _) -> return i
    _            -> execute h insertSQL (Only val)
                 >> lastInsertRowId h
  where
    selectSQL = mkQuery $ "select Id from " ++ table ++ " where " ++ col ++ " = ?"
    insertSQL = mkQuery $ "insert into " ++ table ++ " (" ++ col ++ ") values (?)"

mkQuery :: String -> Query
mkQuery = fromString

getAllSourceFiles :: DBHandle -> IO [CommandInfo]
getAllSourceFiles h = query_ h sql
  where sql = "select F.Name, P.Path, W.Path, C.Command, A.Args, LastBuilt \
              \ from SourceFiles                                           \
              \ join Files as F on SourceFiles.File = F.Id                 \
              \ join Paths as P on SourceFiles.Path = P.Id                 \
              \ join Paths as W on SourceFiles.WorkingDirectory = W.Id     \
              \ join BuildCommands as C on SourceFiles.BuildCommand = C.Id \
              \ join BuildArgs as A on SourceFiles.BuildArgs = A.Id"

getCommandInfo :: DBHandle -> SourceFile -> IO (Maybe CommandInfo)
getCommandInfo h (SourceFile sn sp) = do
    row <- query h sql (sn, sp)
    return $ case row of
              (ci : _) -> Just ci
              _        -> Nothing
  where sql = "select F.Name, P.Path, W.Path, C.Command, A.Args, LastBuilt \
              \ from SourceFiles                                           \
              \ join Files as F on SourceFiles.File = F.Id                 \
              \ join Paths as P on SourceFiles.Path = P.Id                 \
              \ join Paths as W on SourceFiles.WorkingDirectory = W.Id     \
              \ join BuildCommands as C on SourceFiles.BuildCommand = C.Id \
              \ join BuildArgs as A on SourceFiles.BuildArgs = A.Id        \
              \ where F.Name = ? and P.Path = ? limit 1"

-- Eventually this should be more statistical, but right now it will just
-- return an arbitrary file from the same directory.
getSimilarCommandInfo :: DBHandle -> SourceFile -> IO (Maybe CommandInfo)
getSimilarCommandInfo h sf@(SourceFile _ sp) = do
    row <- query h sql (Only sp)
    return $ case row of
              (ci : _) -> Just $ withSourceFile ci sf
              _        -> Nothing
  where sql = "select F.Name, P.Path, W.Path, C.Command, A.Args, LastBuilt \
              \ from SourceFiles                                           \
              \ join Files as F on SourceFiles.File = F.Id                 \
              \ join Paths as P on SourceFiles.Path = P.Id                 \
              \ join Paths as W on SourceFiles.WorkingDirectory = W.Id     \
              \ join BuildCommands as C on SourceFiles.BuildCommand = C.Id \
              \ join BuildArgs as A on SourceFiles.BuildArgs = A.Id        \
              \ where P.Path = ? limit 1"

-- Schema and operations for the Kinds table.
defineKindsTable :: DBHandle -> IO ()
defineKindsTable h = execute_ h sql
  where sql =  "create table if not exists Kinds(        \
               \ Id integer primary key unique not null, \
               \ Kind varchar(2048) unique not null)"

-- Schema and operations for the Definitions table.
defineDefinitionsTable :: DBHandle -> IO ()
defineDefinitionsTable h = execute_ h sql
  where sql =  "create table if not exists Definitions(         \
               \ Name varchar(2048) not null,                   \
               \ USR varchar(2048) unique not null primary key, \
               \ File integer not null,                         \
               \ Path integer not null,                         \
               \ Line integer not null,                         \
               \ Column integer not null,                       \
               \ Kind integer not null,                         \
               \ foreign key(File) references Files(Id),        \
               \ foreign key(Path) references Paths(Id),        \
               \ foreign key(Kind) references Kinds(Id))"

updateDef :: DBHandle -> DefInfo -> IO ()
updateDef h (DefInfo (Identifier n u) (SourceLocation (SourceFile sn sp) l c) k) = do
    execute_ h "begin transaction"
    fileId <- getIdForRow h "Files" "Name" sn
    pathId <- getIdForRow h "Paths" "Path" sp
    kindId <- getIdForRow h "Kinds" "Kind" k
    execute h sql (n, u, fileId, pathId, l, c, kindId)
    execute_ h "commit"
  where
    sql =  "replace into Definitions                     \
           \ (Name, USR, File, Path, Line, Column, Kind) \
           \ values (?, ?, ?, ?, ?, ?, ?)"

getDef :: DBHandle -> Identifier -> IO (Maybe DefInfo)
getDef h (Identifier _ usr) = do
    row <- query h sql (Only $ usr)
    return $ case row of
              (di : _) -> Just di
              _        -> Nothing
  where sql = "select D.Name, D.USR, F.Name, P.Path, D.Line, D.Column, K.Kind \
              \ from Definitions as D                                         \
              \ join Files as F on D.File = F.Id                              \
              \ join Paths as P on D.Path = P.Id                              \
              \ join Kinds as K on D.Kind = K.Id                              \
              \ where D.USR = ? limit 1"
  

-- Checks that the database has the correct schema and sets it up if needed.
ensureSchema :: DBHandle -> IO ()
ensureSchema h = defineMetadataTable h
              >> defineFilesTable h
              >> definePathsTable h
              >> defineBuildCommandsTable h
              >> defineBuildArgsTable h
              >> defineSourceFilesTable h
              >> defineKindsTable h
              >> defineDefinitionsTable h
              >> ensureVersion h

ensureVersion :: DBHandle -> IO ()
ensureVersion h = getDBVersion h >>= checkVersion
  where
    checkVersion (Just (major, minor))
                 | (major, minor) == (dbMajorVersion, dbMinorVersion) = return ()
                 | otherwise = throwDBVersionError major minor
    checkVersion _ = setDBVersion h

throwDBVersionError :: Int64 -> Int64 -> IO ()
throwDBVersionError major minor  =  error $ "Database version "
                                 ++ (show major) ++ "." ++ (show minor)
                                 ++ " is different than required version "
                                 ++ (show dbMajorVersion) ++ "."
                                 ++ (show dbMinorVersion)
