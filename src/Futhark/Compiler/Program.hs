{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

-- | Low-level compilation parts.  Look at "Futhark.Compiler" for a
-- more high-level API.
module Futhark.Compiler.Program
  ( readLibraryWithBasis,
    readImports,
    Imports,
    FileModule (..),
    E.Warnings,
    Basis (..),
    emptyBasis,
  )
where

import Control.Exception
import Control.Monad
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State
import Data.List (intercalate)
import Data.Maybe
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Futhark.Error
import Futhark.FreshNames
import Futhark.Util.Pretty (line, ppr, (</>))
import qualified Language.Futhark as E
import Language.Futhark.Parser
import Language.Futhark.Prelude
import Language.Futhark.Semantic
import qualified Language.Futhark.TypeChecker as E
import Language.Futhark.Warnings
import qualified System.FilePath.Posix as Posix
import System.IO.Error

-- | A little monad for reading and type-checking a Futhark program.
type CompilerM m = ReaderT [FilePath] (StateT ReaderState m)

data ReaderState = ReaderState
  { alreadyImported :: Imports,
    nameSource :: VNameSource,
    warnings :: E.Warnings
  }

-- | Pre-typechecked imports, including a starting point for the name source.
data Basis = Basis
  { basisImports :: Imports,
    basisNameSource :: VNameSource,
    -- | Files that should be implicitly opened.
    basisRoots :: [String]
  }

-- | A basis that contains no imports, and has a properly initialised
-- name source.
emptyBasis :: Basis
emptyBasis =
  Basis
    { basisImports = mempty,
      basisNameSource = src,
      basisRoots = mempty
    }
  where
    src = newNameSource $ E.maxIntrinsicTag + 1

readImport ::
  (MonadError CompilerError m, MonadIO m) =>
  [ImportName] ->
  ImportName ->
  CompilerM m ()
readImport steps include
  | include `elem` steps =
    externalErrorS $
      "Import cycle: "
        ++ intercalate
          " -> "
          (map includeToString $ reverse $ include : steps)
  | otherwise = do
    already_done <- gets $ isJust . lookup (includeToString include) . alreadyImported

    unless already_done $
      uncurry (handleFile steps include) =<< readImportFile include

handleFile ::
  (MonadIO m, MonadError CompilerError m) =>
  [ImportName] ->
  ImportName ->
  T.Text ->
  FilePath ->
  CompilerM m ()
handleFile steps include file_contents file_name = do
  prog <- case parseFuthark file_name file_contents of
    Left err -> externalErrorS $ show err
    Right prog -> return prog

  mapM_ (readImport steps' . uncurry (mkImportFrom include)) $
    E.progImports prog

  -- It is important to not read these before the above calls to
  -- readImport.
  imports <- gets alreadyImported
  src <- gets nameSource
  roots <- ask

  case E.checkProg imports src include $ prependRoots roots prog of
    (prog_ws, Left err) -> do
      prev_ws <- gets warnings
      let ws = prev_ws <> prog_ws
      externalError $
        if anyWarnings ws
          then ppr (prev_ws <> ws) </> line <> ppr err
          else ppr err
    (ws, Right (m, src')) ->
      modify $ \s ->
        s
          { alreadyImported = (includeToString include, m) : imports,
            nameSource = src',
            warnings = warnings s <> ws
          }
  where
    steps' = include : steps

readFileSafely :: String -> IO (Maybe (Either String (String, T.Text)))
readFileSafely filepath =
  (Just . Right . (filepath,) <$> T.readFile filepath) `catch` couldNotRead
  where
    couldNotRead e
      | isDoesNotExistError e =
        return Nothing
      | otherwise =
        return $ Just $ Left $ show e

readImportFile ::
  (MonadError CompilerError m, MonadIO m) =>
  ImportName ->
  m (T.Text, FilePath)
readImportFile include = do
  -- First we try to find a file of the given name in the search path,
  -- then we look at the builtin library if we have to.  For the
  -- builtins, we don't use the search path.
  r <- liftIO $ readFileSafely $ includeToFilePath include
  case (r, lookup prelude_str prelude) of
    (Just (Right (filepath, s)), _) -> return (s, filepath)
    (Just (Left e), _) -> externalErrorS e
    (Nothing, Just t) -> return (t, prelude_str)
    (Nothing, Nothing) -> externalErrorS not_found
  where
    prelude_str = "/" Posix.</> includeToString include Posix.<.> "fut"

    not_found =
      "Error at " ++ E.locStr (E.srclocOf include)
        ++ ": could not find import '"
        ++ includeToString include
        ++ "'."

-- | Read Futhark files from some basis, and printing log messages if
-- the first parameter is True.
readLibraryWithBasis ::
  (MonadError CompilerError m, MonadIO m) =>
  Basis ->
  [FilePath] ->
  m
    ( E.Warnings,
      Imports,
      VNameSource
    )
readLibraryWithBasis builtin fps = do
  (_, imps, src) <-
    runCompilerM builtin $
      readImport [] $ mkInitialImport "/prelude/prelude"
  let basis = Basis imps src ["/prelude/prelude"]
  readLibrary' basis fps

-- | Read and type-check a Futhark library (multiple files, relative
-- to the same search path), including all imports.
readLibrary' ::
  (MonadError CompilerError m, MonadIO m) =>
  Basis ->
  [FilePath] ->
  m
    ( E.Warnings,
      Imports,
      VNameSource
    )
readLibrary' basis fps = runCompilerM basis $ mapM onFile fps
  where
    onFile fp = do
      r <- liftIO $ readFileSafely fp
      case r of
        Just (Right (_, fs)) ->
          handleFile [] (mkInitialImport fp_name) fs fp
        Just (Left e) -> externalErrorS e
        Nothing -> externalErrorS $ fp ++ ": file not found."
      where
        (fp_name, _) = Posix.splitExtension fp

-- | Read and type-check Futhark imports (no @.fut@ extension; may
-- refer to baked-in prelude).  This is an exotic operation that
-- probably only makes sense in an interactive environment.
readImports ::
  (MonadError CompilerError m, MonadIO m) =>
  Basis ->
  [ImportName] ->
  m
    ( E.Warnings,
      Imports,
      VNameSource
    )
readImports basis imps =
  runCompilerM basis $ mapM (readImport []) imps

runCompilerM ::
  Monad m =>
  Basis ->
  CompilerM m a ->
  m (E.Warnings, [(String, FileModule)], VNameSource)
runCompilerM (Basis imports src roots) m = do
  let s = ReaderState (reverse imports) src mempty
  s' <- execStateT (runReaderT m roots) s
  return
    ( warnings s',
      reverse $ alreadyImported s',
      nameSource s'
    )

prependRoots :: [FilePath] -> E.UncheckedProg -> E.UncheckedProg
prependRoots roots (E.Prog doc ds) =
  E.Prog doc $ map mkImport roots ++ ds
  where
    mkImport fp =
      -- We do not use ImportDec here, because we do not want the
      -- type checker to issue a warning about a redundant import.
      E.LocalDec (E.OpenDec (E.ModImport fp E.NoInfo mempty) mempty) mempty
