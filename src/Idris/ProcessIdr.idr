module Idris.ProcessIdr

import Core.Binary
import Core.Context
import Core.Directory
import Core.Env
import Core.Hash
import Core.Metadata
import Core.Options
import Core.Unify

import TTImp.Elab.Check
import TTImp.TTImp

import Idris.Desugar
import Idris.Parser
import Idris.REPLCommon
import Idris.REPLOpts
import Idris.Syntax

import Data.NameMap

import Control.Catchable

processDecl : {auto c : Ref Ctxt Defs} ->
              {auto u : Ref UST UState} ->
              {auto s : Ref Syn SyntaxInfo} ->
              {auto m : Ref MD Metadata} ->
              PDecl -> Core (Maybe Error)
processDecl decl
    = catch (do impdecls <- desugarDecl [] decl 
                traverse (Check.processDecl [] (MkNested []) []) impdecls
                pure Nothing)
            (\err => do giveUpConstraints -- or we'll keep trying...
                        pure (Just err))

processDecls : {auto c : Ref Ctxt Defs} ->
               {auto u : Ref UST UState} ->
               {auto s : Ref Syn SyntaxInfo} ->
               {auto m : Ref MD Metadata} ->
               List PDecl -> Core (List Error)
processDecls decls
    = do xs <- traverse processDecl decls
         Nothing <- checkDelayedHoles 
             | Just err => pure (case mapMaybe id xs of
                                      [] => [err]
                                      errs => errs)
         pure (mapMaybe id xs)

readModule : {auto c : Ref Ctxt Defs} ->
             {auto u : Ref UST UState} ->
             {auto s : Ref Syn SyntaxInfo} ->
             (top : Bool) ->
             FC ->
             (visible : Bool) -> -- Is import visible to top level module?
             (reexp : Bool) -> -- Should the module be reexported?
             (imp : List String) -> -- Module name to import
             (as : List String) -> -- Namespace to import into
             Core ()
readModule top loc vis reexp imp as
    = do Right fname <- nsToPath loc imp
               | Left err => throw err
         Just (syn, hash, more) <- logTime ("Reading " ++ show imp) $
                                         readFromTTC {extra = SyntaxInfo} 
                                                  loc vis fname imp as
              | Nothing => when vis (setVisible imp) -- already loaded, just set visibility
         addImported (imp, reexp, as)
         extendAs imp as syn

         defs <- get Ctxt
         when top $ put Ctxt (record { importHashes $= ((as, hash) ::) } defs)

         modNS <- getNS
         when vis $ setVisible imp
         traverse_ (\ mimp => 
                       do let m = fst mimp
                          let reexp = fst (snd mimp)
                          let as = snd (snd mimp)
                          readModule False loc (vis && reexp) reexp m as) more
         setNS modNS

readImport : {auto c : Ref Ctxt Defs} ->
             {auto u : Ref UST UState} ->
             {auto s : Ref Syn SyntaxInfo} ->
             Import -> Core ()
readImport imp
    = readModule True (loc imp) True (reexport imp) (path imp) (nameAs imp)

readHash : {auto c : Ref Ctxt Defs} ->
           {auto u : Ref UST UState} ->
           Import -> Core (List String, Int)
readHash imp
    = do Right fname <- nsToPath (loc imp) (path imp)
               | Left err => throw err
         h <- readIFaceHash fname
         -- If the import is a 'public' import, then it forms part of
         -- our own interface so add its hash to our hash
         when (reexport imp) $ 
            do log 5 $ "Reexporting " ++ show (path imp) ++ " hash " ++ show h
               addHash h
         pure (nameAs imp, h)

prelude : Import
prelude = MkImport (MkFC "(implicit)" (0, 0) (0, 0)) False
                     ["Prelude"] ["Prelude"]

export
readPrelude : {auto c : Ref Ctxt Defs} ->
              {auto u : Ref UST UState} ->
              {auto s : Ref Syn SyntaxInfo} ->
              Core ()
readPrelude = do readImport prelude 
                 setNS ["Main"]

-- Import a TTC for use as the main file (e.g. at the REPL)
export
readAsMain : {auto c : Ref Ctxt Defs} ->
             {auto u : Ref UST UState} ->
             {auto s : Ref Syn SyntaxInfo} ->
             (fname : String) -> Core ()
readAsMain fname
    = do Just (syn, _, more) <- readFromTTC {extra = SyntaxInfo} 
                                             toplevelFC True fname [] []
              | Nothing => throw (InternalError "Already loaded")
         replNS <- getNS
         replNestedNS <- getNestedNS
         extendAs replNS replNS syn

         ustm <- get UST
         traverse (\ mimp => 
                       do let m = fst mimp
                          let as = snd (snd mimp)
                          fname <- nsToPath emptyFC m
                          readModule False emptyFC True False m as) more

         -- We're in the namespace from the first TTC, so use the next name
         -- from that for the fresh metavariable name generation
         -- TODO: Maybe we should record this per namespace, since this is
         -- a little bit of a hack? Or maybe that will have too much overhead.
         ust <- get UST
         put UST (record { nextName = nextName ustm } ust)

         setNS replNS
         setNestedNS replNestedNS

addPrelude : List Import -> List Import
addPrelude imps 
  = if not (["Prelude"] `elem` map path imps)
       then prelude :: imps
       else imps

-- Get a file's modified time. If it doesn't exist, return 0 (that is, it
-- was last modified at the dawn of time so definitely out of date for
-- rebuilding purposes...)
modTime : String -> Core Integer
modTime fname
    = do Right f <- coreLift $ openFile fname Read
             | Left err => pure 0 -- Beginning of Time :)
         Right t <- coreLift $ fileModifiedTime f
             | Left err => do coreLift $ closeFile f
                              pure 0
         coreLift $ closeFile f
         pure t

export
getParseErrorLoc : String -> ParseError -> FC
getParseErrorLoc fname (ParseFail _ (Just pos) _) = MkFC fname pos pos
getParseErrorLoc fname (LexFail (l, c, _)) = MkFC fname (l, c) (l, c)
getParseErrorLoc fname _ = replFC

-- Process everything in the module; return the syntax information which
-- needs to be written to the TTC (e.g. exported infix operators)
-- Returns 'Nothing' if it didn't reload anything
processMod : {auto c : Ref Ctxt Defs} ->
             {auto u : Ref UST UState} ->
             {auto s : Ref Syn SyntaxInfo} ->
             {auto m : Ref MD Metadata} ->
             {auto o : Ref ROpts REPLOpts} ->
             (srcf : String) -> (ttcf : String) -> (msg : String) ->
             Module -> 
             (sourcecode : String) ->
             Core (Maybe (List Error))
processMod srcf ttcf msg mod sourcecode
    = catch (do let ns = moduleNS mod
                when (ns /= ["Main"]) $
                   do let MkFC fname _ _ = headerloc mod
                      d <- getDirs
                      when (pathToNS (working_dir d) fname /= ns) $
                          throw (GenericMsg (headerloc mod) 
                                   ("Module name " ++ showSep "." (reverse ns) ++
                                    " does not match file name " ++ fname))
                -- Add an implicit prelude import
                let imps =
                     if (noprelude !getSession || moduleNS mod == ["Prelude"])
                        then imports mod
                        else addPrelude (imports mod)

                hs <- traverse readHash imps
                defs <- get Ctxt
                log 5 $ "Current hash " ++ show (ifaceHash defs)
                log 5 $ show (moduleNS mod) ++ " hashes:\n" ++
                        show (sort hs)
                imphs <- readImportHashes ttcf
                log 5 $ "Old hashes from " ++ ttcf ++ ":\n" ++ show (sort imphs)

                -- If the old hashes are the same as the hashes we've just
                -- read from the imports, and the source file is older than
                -- the ttc, we can skip the rest.
                srctime <- modTime srcf
                ttctime <- modTime ttcf

                if (sort hs == sort imphs && srctime <= ttctime)
                   then -- Hashes the same, source up to date, just set the namespace
                        -- for the REPL
                        do setNS ns
                           pure Nothing
                   else 
                     do iputStrLn msg
                        -- read imports here
                        -- Note: We should only import .ttc - assumption is that there's
                        -- a phase before this which builds the dependency graph
                        -- (also that we only build child dependencies if rebuilding
                        -- changes the interface - will need to store a hash in .ttc!)
                        logTime "Reading imports" $
                           traverse_ readImport imps

                        -- Before we process the source, make sure the "hide_everywhere"
                        -- names are set to private (TODO, maybe if we want this?)
--                         defs <- get Ctxt
--                         traverse (\x => setVisibility emptyFC x Private) (hiddenNames defs)
                        setNS ns
                        errs <- logTime "Processing decls" $
                                    processDecls (decls mod)
                        pure (Just errs))
          (\err => pure (Just [err]))

-- Process a file. Returns any errors, rather than throwing them, because there
-- might be lots of errors collected across a whole file.
export
process : {auto c : Ref Ctxt Defs} ->
          {auto m : Ref MD Metadata} ->
          {auto u : Ref UST UState} ->
          {auto s : Ref Syn SyntaxInfo} ->
          {auto o : Ref ROpts REPLOpts} ->
          String -> FileName -> 
          Core (List Error)
process buildmsg file
    = do Right res <- coreLift (readFile file)
               | Left err => pure [FileErr file err]
         parseRes <- logTime ("Parsing " ++ file) $
                    pure (runParser res (do p <- prog file; eoi; pure p))
         case parseRes of
              Left err => pure [ParseFail (getParseErrorLoc file err) err]
              Right mod =>
                -- Processing returns a list of errors across a whole module,
                -- but may fail for other reasons, so we still need to catch
                -- other possible errors
                    catch (do initHash
                              resetNextVar
                              fn <- getTTCFileName file ".ttc"
                              Just errs <- logTime ("Elaborating " ++ file) $
                                              processMod file fn buildmsg mod res
                                   | Nothing => pure [] -- skipped it
                              if isNil errs
                                 then
                                   logTime ("Writing TTC/TTM for " ++ file) $
                                     do defs <- get Ctxt
                                        d <- getDirs
                                        makeBuildDirectory (pathToNS (working_dir d) file)
                                        writeToTTC !(get Syn) fn
                                        mfn <- getTTCFileName file ".ttm"
                                        writeToTTM mfn
                                        pure []
                                 else do pure errs)
                          (\err => pure [err])
