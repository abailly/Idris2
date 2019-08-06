||| Provides process-level capability to exit a running program
module System.Exit

import Data.So

||| Programs can either terminate successfully, or end in a caught
||| failure.
public export
data ExitCode : Type where
  ||| Terminate successfully.
  ExitSuccess : ExitCode
  ||| Program terminated for some prescribed reason.
  |||
  ||| @errNo A non-zero numerical value indicating failure.
  ||| @prf   Proof that the int value is non-zero.
  ExitFailure : (errNo    : Int)
             -> {auto prf : So (not $ errNo == 0)}
             -> ExitCode

||| Quit with a particular exit code
||| For chez scheme, see: http://cisco.github.io/ChezScheme/csug9.5/system.html#./system:s161
exit : {a : Type} -> Int -> IO a
exit code = schemeCall a "exit" [ code ]

||| Terminate the program with an `ExitCode`. This code indicates the
||| success of the program's execution, and returns the success code
||| to the program's caller.
|||
||| @code The `ExitCode` for program.
export
exitWith : (code : ExitCode) -> IO a
exitWith ExitSuccess         = exit 0
exitWith (ExitFailure errNo) = exit errNo

||| Exit the program indicating failure.
export
exitFailure : IO a
exitFailure = exitWith (ExitFailure 1)

||| Exit the program after a successful run.
export
exitSuccess : IO a
exitSuccess = exitWith ExitSuccess
