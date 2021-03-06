{-# LANGUAGE GADTs,
             OverloadedStrings #-}

module Main where

import Language.Hakaru.Evaluation.ConstantPropagation
import Language.Hakaru.Syntax.TypeCheck
import Language.Hakaru.Syntax.AST.Transforms (expandTransformations)
import Language.Hakaru.Command
import Language.Hakaru.CodeGen.Wrapper
import Language.Hakaru.CodeGen.Pretty       

import           Control.Monad.Reader
import           Data.Text hiding (any,map,filter)
import qualified Data.Text.IO as IO
import           Text.PrettyPrint (render)       
import           Options.Applicative
import           System.IO
import           System.Process
import           System.Exit

data Options =
 Options { debug    :: Bool
         , optimize :: Bool
         -- , accelerate :: Either CUDA OpenCL
         -- , jobs       :: Maybe Int
         , make     :: Maybe String
         , asFunc   :: Maybe String
         , fileIn   :: String
         , fileOut  :: Maybe String
         } deriving Show


main :: IO ()
main = do
  opts <- parseOpts
  prog <- readFromFile (fileIn opts)
  runReaderT (compileHakaru prog) opts

options :: Parser Options
options = Options
  <$> switch ( long "debug"
             <> short 'D'
             <> help "Prints Hakaru src, Hakaru AST, C AST, C src" )
  <*> switch ( long "optimize"
             <> short 'O'
             <> help "Performs constant folding on Hakaru AST" )
  <*> (optional $ strOption ( long "make"
                            <> short 'm'
                            <> help "Compiles generated C code with the compiler ARG"))
  <*> (optional $ strOption ( long "as-function"
                            <> short 'F'
                            <> help "Compiles to a sampling C function with the name ARG" ))
  <*> strArgument (metavar "INPUT" <> help "Program to be compiled")
  <*> (optional $ strOption (short 'o' <> metavar "OUTPUT" <> help "output FILE"))

parseOpts :: IO Options
parseOpts = execParser $ info (helper <*> options)
                       $ fullDesc <> progDesc "Compile Hakaru to C"

compileHakaru :: Text -> ReaderT Options IO ()
compileHakaru prog = ask >>= \config -> lift $ do
  case parseAndInfer prog of
    Left err -> IO.putStrLn err
    Right (TypedAST typ ast) -> do
      let ast'    = TypedAST typ $ if optimize config
                                   then constantPropagation . expandTransformations $  ast
                                   else expandTransformations ast
          outPath = case fileOut config of
                      (Just f) -> f
                      Nothing  -> "-"
          cast    = wrapProgram ast' (asFunc config)
          output  = pack . render . pretty $ cast
      when (debug config) $ do
        putErrorLn hrule
        putErrorLn $ pack $ show ast
        when (optimize config) $ do
          putErrorLn hrule
          putErrorLn $ pack $ show ast'
        putErrorLn hrule
        putErrorLn $ pack $ show cast  
        putErrorLn hrule
      case make config of
        Nothing -> writeToFile outPath output
        Just cc -> makeFile cc (fileOut config) $ unpack output

  where hrule = "\n----------------------------------------------------------------\n"

putErrorLn :: Text -> IO ()
putErrorLn = IO.hPutStrLn stderr


makeFile :: String -> Maybe String -> String -> IO ()
makeFile cc mout prog =
  do let p = proc cc $ ["-pedantic"
                       ,"-std=c99"
                       ,"-lm"
                       ,"-xc"
                       ,"-"]
                       ++ (case mout of
                            Nothing -> []
                            Just o  -> ["-o " ++ o])
     (Just inH, _, _, pH) <- createProcess p { std_in    = CreatePipe
                                             , std_out   = CreatePipe }
     hPutStrLn inH prog
     hClose inH
     exit <- waitForProcess pH
     case exit of
       ExitSuccess -> return ()
       _           -> error $ cc ++ " returned exit code: " ++ show exit
