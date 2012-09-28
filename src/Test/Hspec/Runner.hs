-- | This module contains the runners that take a set of specs, evaluate their examples, and
-- report to a given handle.
--
module Test.Hspec.Runner (
  Specs
, hspec
, hspecWith
, hspecB
, toExitCode

, Summary (..)

, Config (..)
, ColorMode (..)
, defaultConfig

-- * Deprecated functions
, hspecX
, hHspec
, hHspecWithFormat
) where

import           Control.Monad (unless, (>=>), guard)
import           Control.Applicative
import           Data.Monoid
import           Data.Maybe
import           System.IO
import           System.Environment
import           System.Exit
import           System.IO.Silently (silence)

import           Test.Hspec.Util (safeEvaluate)
import           Test.Hspec.Internal
import           Test.Hspec.Config
import           Test.Hspec.Formatters
import           Test.Hspec.Formatters.Internal

-- | Filter specs by given predicate.
--
-- The predicate takes a list of "describe" labels and a "requirement".
filterSpecs :: ([String] -> String -> Bool) -> Specs -> Specs
filterSpecs p = goSpecs []
  where
    goSpecs :: [String] -> [Spec] -> [Spec]
    goSpecs groups = catMaybes . map (goSpec groups)

    goSpec :: [String] -> Spec -> Maybe Spec
    goSpec groups spec = case spec of
      SpecExample requirement _ -> guard (p groups requirement) >> return spec
      SpecGroup group specs     -> case goSpecs (groups ++ [group]) specs of
        [] -> Nothing
        xs -> Just (SpecGroup group xs)

-- | Evaluate and print the result of checking the spec examples.
runFormatter :: Config -> Formatter -> Spec -> FormatM ()
runFormatter c formatter = go []
  where
    silence_
      | configVerbose c = id
      | otherwise       = silence

    go :: [String] -> Spec -> FormatM ()
    go groups (SpecGroup group xs) = do
      exampleGroupStarted formatter groups group
      mapM_ (go (group : groups)) xs
    go groups (SpecExample requirement example) = do
      result <- (liftIO . safeEvaluate . silence_) (example c)
      case result of
        Right Success -> do
          increaseSuccessCount
          exampleSucceeded formatter groups requirement
        Right (Pending reason) -> do
          increasePendingCount
          examplePending formatter groups requirement reason

        Right (Fail err) -> failed (Right err)
        Left e           -> failed (Left  e)
      where
        failed err = do
          increaseFailCount
          addFailMessage groups requirement err
          exampleFailed  formatter groups requirement err

-- | Create a document of the given specs and write it to stdout.
--
-- Exit the program with `exitFailure` if at least one example fails.
hspec :: Specs -> IO ()
hspec specs =
  getConfig >>=
  withArgs [] .             -- do not leak command-line arguments to examples
  (`hspecB_` specs) >>=
  (`unless` exitFailure)

{-# DEPRECATED hspecX "use hspec instead" #-}
hspecX :: Specs -> IO a
hspecX = hspecB >=> exitWith . toExitCode

{-# DEPRECATED hHspec "use hspecWith instead" #-}
hHspec :: Handle -> Specs -> IO Summary
hHspec h = hspecWith defaultConfig {configHandle = h}

{-# DEPRECATED hHspecWithFormat "use hspecWith instead" #-}
hHspecWithFormat :: Config -> Handle -> Specs -> IO Summary
hHspecWithFormat c h = hspecWith c {configHandle = h}

-- | Create a document of the given specs and write it to stdout.
--
-- Return `True` if all examples passed, `False` otherwise.
hspecB :: Specs -> IO Bool
hspecB = hspecB_ defaultConfig

hspecB_ :: Config -> Specs -> IO Bool
hspecB_ c = fmap success . hspecWith c
  where
    success :: Summary -> Bool
    success s = summaryFailures s == 0

-- | Run given specs.  This is similar to `hspec`, but more flexible.
hspecWith :: Config -> Specs -> IO Summary
hspecWith c specs = do
  useColor <- doesUseColor h c
  runFormatM useColor h $ do
    mapM_ (runFormatter c formatter) (maybe id filterSpecs (configFilterPredicate c) specs)
    failedFormatter formatter
    footerFormatter formatter
    Summary <$> getTotalCount <*> getFailCount
  where
    formatter = configFormatter c
    h = configHandle c

doesUseColor :: Handle -> Config -> IO Bool
doesUseColor h c = case configColorMode c of
  ColorAuto  -> hIsTerminalDevice h
  ColorNever -> return False
  ColorAlway -> return True

toExitCode :: Bool -> ExitCode
toExitCode True  = ExitSuccess
toExitCode False = ExitFailure 1

-- | Summary of a test run.
data Summary = Summary {
  summaryExamples :: Int
, summaryFailures :: Int
} deriving (Eq, Show)

instance Monoid Summary where
  mempty = Summary 0 0
  (Summary x1 x2) `mappend` (Summary y1 y2) = Summary (x1 + y1) (x2 + y2)
