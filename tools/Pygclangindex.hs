import Control.Applicative
import Control.Monad
import Control.Monad.Trans
import Data.ByteString.Char8 (ByteString)
import Data.Conduit
import Data.Conduit.Binary
import Data.Conduit.Cereal
import Data.Maybe
import Data.Serialize
import qualified Data.Text as T
import System.Directory
import System.IO

import Pygmalion.Analysis.ClangRequest
import Pygmalion.Analysis.Source
import Pygmalion.Core
import Pygmalion.Log

main :: IO ()
main = do
    initLogger EMERGENCY
    logDebug "Starting clang analysis process"
    wd <- T.pack <$> getCurrentDirectory
    sas <- mkSourceAnalysisState wd
    runResourceT (sourceHandle stdin $= conduitGet getReq =$= process sas =$= conduitPut putResp $$ sinkHandle stdout)
  where
    getReq = get :: Get ClangRequest
    putResp :: Putter ClangResponse
    putResp p = put p
    process :: SourceAnalysisState -> Conduit ClangRequest (ResourceT IO) ClangResponse
    process sas = do
      req <- await
      case req of
        Just (Analyze ci) -> do results <- liftIO $ doAnalyze sas ci
                                when (isJust results) $
                                  mapM_ (yield . FoundDef) (fromJust results)
                                yield EndOfDefs
                                process sas
        Just Shutdown     -> liftIO (logDebug "Shutting down clang analysis process") >> return ()
        Nothing           -> liftIO (logError "Clang analysis process encountered an error") >> return ()

doAnalyze :: SourceAnalysisState -> CommandInfo -> IO (Maybe [DefInfo])
doAnalyze sas ci = do
  liftIO $ logDebug $ "Analyzing " ++ (show . ciSourceFile $ ci)
  result <- liftIO $ runSourceAnalyses sas ci
  case result of
    Just (_, ds) -> return $! (Just ds)
    Nothing      -> return $! Nothing
