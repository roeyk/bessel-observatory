{-
  Bessel Observatory: validate observations, compute J0 in separate OS workers, and save ordered CSV.
  The parent reads input and owns result ordering; the worker computes the midpoint approximation.
  An invalid observation is skipped with a warning, while failed I/O or workers abort the run.
-}
{-# LANGUAGE ScopedTypeVariables #-}
-- GHC 9.x, process + unix packages. Pure numerical core, bracketed IO effects.
import Control.Exception
import Control.Monad (when, foldM)
import Foreign.Marshal.Array (withArray)
import Foreign.Ptr (plusPtr)
import Foreign.Storable (peek, sizeOf)
import System.Environment (getArgs, getExecutablePath)
import System.Exit
import System.IO
import System.Posix.Process (getProcessID)
import System.Process
import Text.Read (readMaybe)

{-
  Validate a numeric token while keeping the parser free of IO effects.
  Inputs: A candidate String.
  Outputs: Either a diagnostic or a bounded Double.
  Used by: readValues and the internal worker branch of run.
-}
number :: String -> Either String Double
number s = case readMaybe s of
  Just x | not (isNaN x || isInfinite x) && abs x <= 1000 -> Right x
  _ -> Left "expected finite x in [-1000,1000]"

{-
  Describe the midpoint values as a pure sequence.
  Inputs: A validated Double x.
  Outputs: The list of 16,384 integrand samples.
  Used by: j0 before it creates a scoped foreign-memory view.
-}
samples :: Double -> [Double]
samples x = [cos (x * sin (pi * (fromIntegral k + 0.5) / 16384)) | k <- [0..16383 :: Int]]

{-
  Reduce sample storage through explicit pointer reads in IO.
  Inputs: A bounded Double x.
  Outputs: An IO action yielding approximate J0.
  Used by: run in worker mode.
-}
j0 :: Double -> IO Double
j0 x = withArray (samples x) $ \base -> do
  {-
    withArray brackets the allocation. plusPtr counts bytes; peek is an
    explicit IO effect, and all offsets refer to initialized Double values.
    Accumulate values read at element-sized byte offsets while withArray keeps the allocation alive.
  -}
  total <- foldM (\acc k -> do
    value <- peek (base `plusPtr` (k * sizeOf (0 :: Double)))
    pure (acc + value)) 0 [0..16383]
  pure (total / 16384)

{-
  Read ordered observations and recover from invalid numeric lines.
  Inputs: An input Handle.
  Outputs: An IO action yielding the accepted values.
  Used by: run before launching workers.
-}
readValues :: Handle -> IO [Double]
readValues handle = go [] (0 :: Int)
  where
    {-
      Continue reading with bounded reverse-order accumulation.
      Inputs: Accepted values so far and their count; the input handle is captured.
      Outputs: The final ordered values or a fatal input-limit/read error.
      Used by: readValues and its own recursive continuation.
    -}
    go acc n = do
      eof <- hIsEOF handle
      if eof then pure (reverse acc) else do
        line <- hGetLine handle
        case dropWhile (`elem` " \t\r") line of
          "" -> pure (reverse acc)
          '#':_ -> go acc n
          text -> case number text of
            Left message -> hPutStrLn stderr ("warning: " ++ message ++ "; skipped") >> go acc n
            Right x -> if n == 4096 then ioError (userError "at most 4096 values") else go (x:acc) (n+1)

{-
  Start a bounded set of executable children and collect their rows.
  Inputs: This executable path and a group of x values.
  Outputs: An IO action yielding rows in original order.
  Used by: run through mapM over input chunks.
-}
batch :: FilePath -> [Double] -> IO [String]
batch executable = launch []
  where
    {-
      Nested brackets keep every child alive until all have been launched.
      Keep all child lifetimes nested until the full batch is launched.
      Inputs: Pending child handles and the remaining values.
      Outputs: The collected rows; withCreateProcess cleans up each child scope.
      Used by: batch and recursive launch calls.
    -}
    launch pending [] = mapM collect (reverse pending)
    launch pending (x:xs) = withCreateProcess
      (proc executable ["--worker", show x]) { std_in = NoStream, std_out = CreatePipe }
      (\_ out _ ph -> case out of
        Just h -> launch ((h,ph):pending) xs
        Nothing -> ioError (userError "missing worker pipe"))
    {-
      Force a child output string before closing its lazy stream.
      Inputs: The child output handle and process handle.
      Outputs: One complete row, or an IO error for failed/empty output.
      Used by: launch after the final child is started.
    -}
    collect (h,ph) = do
      row <- hGetContents h
      _ <- evaluate (length row) -- Drain lazy IO before waiting/closing the pipe.
      status <- waitForProcess ph
      if status == ExitSuccess && not (null row) then pure row
      else ioError (userError "worker failed")

{-
  Partition a list without changing its sequence.
  Inputs: A positive group size and a list.
  Outputs: Successive groups with at most that many elements.
  Used by: run to enforce the worker limit.
-}
chunks :: Int -> [a] -> [[a]]
chunks _ [] = []
chunks n xs = let (a,b) = splitAt n xs in a : chunks n b

{-
  Choose help, worker calculation, or the complete experiment.
  Inputs: The process argument strings.
  Outputs: An IO action that writes results or raises an exception.
  Used by: main behind the final error boundary.
-}
run :: [String] -> IO ()
run ["--help"] = putStrLn "Usage: bessel-haskell [INPUT|- [OUTPUT [WORKERS 1..16]]]"
run ["--worker", text] = do
  x <- either (ioError . userError) pure (number text)
  pid <- getProcessID
  y <- j0 x
  putStrLn (show x ++ "," ++ show y ++ "," ++ show pid)
run args = do
  when (length args > 3) $ ioError (userError "too many arguments")
  let source = case args of x:_ -> x; _ -> "-"
      target = case args of _:x:_ -> x; _ -> "results.csv"
      jobsMaybe = case args of _:_:x:_ -> readMaybe x; _ -> Just 2
  jobs <- case jobsMaybe of
    Just n | n >= 1 && n <= 16 -> pure n
    _ -> ioError (userError "workers must be 1..16")
  -- Choose an interactive handle or a scoped file without changing the reader logic.
  values <- if source == "-"
    then hPutStrLn stderr "Enter one x per line; blank line or EOF finishes:" >> readValues stdin
    else withFile source ReadMode readValues
  when (null values) $ ioError (userError "no valid input values")
  executable <- getExecutablePath
  -- Finish groups in sequence while each group itself runs concurrent child processes.
  rows <- concat <$> mapM (batch executable) (chunks jobs values)
  -- Write the complete output within an automatically closed file scope.
  withFile target WriteMode $ \h -> hPutStr h ("x,j0,worker_pid\n" ++ concat rows)
  putStrLn ("Wrote " ++ show (length rows) ++ " observations to " ++ target)

{-
  Run the CLI and render exceptions as readable failures.
  Inputs: The environment argument list obtained by getArgs.
  Outputs: Console output and success/failure process status.
  Used by: The Haskell runtime.
-}
main :: IO ()
main = (getArgs >>= run) `catch` \(e :: SomeException) -> do
  hPutStrLn stderr ("error: " ++ displayException e)
  exitFailure
