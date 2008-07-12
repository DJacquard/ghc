
import Data.Maybe
import Distribution.PackageDescription
import Distribution.PackageDescription.Parse
import Distribution.ReadE
import Distribution.Simple
import Distribution.Simple.Configure
import Distribution.Simple.LocalBuildInfo
import Distribution.Simple.Program
import Distribution.Simple.Setup
import Distribution.Simple.Utils
import Distribution.Text
import Distribution.Verbosity
import System.Environment

main :: IO ()
main
  = do args <- getArgs
       case args of
           "install" : ghcpkg : ghcpkgconf : destdir : topdir :
                    iprefix : ibindir : ilibdir : ilibexecdir : idynlibdir :
                    idatadir : idocdir : ihtmldir : ihaddockdir :
                    args' ->
               case parseArgs args' of
                   (verbosity, distPref, enableShellWrappers) ->
                       doInstall verbosity distPref enableShellWrappers
                                 ghcpkg ghcpkgconf destdir topdir
                                 iprefix ibindir ilibdir ilibexecdir
                                 idynlibdir idatadir idocdir ihtmldir
                                 ihaddockdir
           _ ->
               error ("Bad arguments: " ++ show args)

-- XXX We should really make Cabal do the hardwork here
parseArgs :: [String]
          -> (Verbosity, -- verbosity
              FilePath,  -- dist prefix
              Bool)      -- enable shell wrappers?
parseArgs = f normal defaultDistPref False
    where f v dp esw (('-':'v':val):args)
              = f (readEOrFail flagToVerbosity val) dp esw args
          f v _  esw ("--distpref":dp:args) = f v dp esw args
          f v dp _   ("--enable-shell-wrappers":args) = f v dp True args
          f v dp esw [] = (v, dp, esw)
          f _ _  _   args = error ("Bad arguments: " ++ show args)

doInstall :: Verbosity -> FilePath -> Bool
          -> FilePath -> FilePath -> FilePath -> FilePath
          -> FilePath -> FilePath -> FilePath -> FilePath -> FilePath
          -> FilePath -> FilePath -> FilePath -> FilePath
          -> IO ()
doInstall verbosity distPref enableShellWrappers
     ghcpkg ghcpkgconf destdir topdir
     iprefix ibindir ilibdir ilibexecdir idynlibdir idatadir
     idocdir ihtmldir ihaddockdir =
       do let userHooks = simpleUserHooks
              copyto = if null destdir then NoCopyDest else CopyTo destdir
              copyFlags = defaultCopyFlags {
                              copyUseWrapper = toFlag enableShellWrappers,
                              copyDest = toFlag copyto,
                              copyVerbosity = toFlag verbosity
                          }
              registerFlags = defaultRegisterFlags {
                                  regPackageDB = toFlag GlobalPackageDB,
                                  regVerbosity = toFlag verbosity,
                                  regGenScript = toFlag $ False,
                                  regInPlace = toFlag $ False
                              }
          lbi <- getConfig verbosity distPref
          let pd = localPkgDescr lbi
              i = installDirTemplates lbi
              -- This is an almighty hack. We need to register
              -- ghc-prim:GHC.Prim, but it doesn't exist, get built, get
              -- haddocked, get copied, etc.
              pd_reg = if packageName pd == PackageName "ghc-prim"
                       then case library pd of
                            Just lib ->
                                let ems = fromJust (simpleParse "GHC.Prim")
                                        : exposedModules lib
                                    lib' = lib { exposedModules = ems }
                                in pd { library = Just lib' }
                            Nothing ->
                                error "Expected a library, but none found"
                       else pd
              -- When coying, we need to actually give a concrete
              -- directory to copy to rather than "$topdir"
              toPathTemplate' = toPathTemplate . replaceTopdir topdir
              i_copy = i { prefix       = toPathTemplate' iprefix,
                           bindir       = toPathTemplate' ibindir,
                           libdir       = toPathTemplate' ilibdir,
                           dynlibdir    = toPathTemplate' idynlibdir,
                           libexecdir   = toPathTemplate' ilibexecdir,
                           datadir      = toPathTemplate' idatadir,
                           docdir       = toPathTemplate' idocdir,
                           htmldir      = toPathTemplate' ihtmldir,
                           haddockdir   = toPathTemplate' ihaddockdir
                         }
              lbi_copy = lbi { installDirTemplates = i_copy }
              -- When we run GHC we give it a $topdir that includes the
              -- $compiler/lib/ part of libsubdir, so we only want the
              -- $pkgid part in the package.conf file. This is a bit of
              -- a hack, really.
              progs = withPrograms lbi
              prog = ConfiguredProgram {
                         programId = programName ghcPkgProgram,
                         programVersion = Nothing,
                         programArgs = ["--force", "--global-conf", ghcpkgconf],
                         programLocation = UserSpecified ghcpkg
                     }
              progs' = updateProgram prog progs
              i_reg = i { prefix       = toPathTemplate iprefix,
                          bindir       = toPathTemplate ibindir,
                          libdir       = toPathTemplate ilibdir,
                          dynlibdir    = toPathTemplate idynlibdir,
                          libexecdir   = toPathTemplate ilibexecdir,
                          datadir      = toPathTemplate idatadir,
                          docdir       = toPathTemplate idocdir,
                          htmldir      = toPathTemplate ihtmldir,
                          haddockdir   = toPathTemplate ihaddockdir
                        }
              lbi_reg = lbi { installDirTemplates = i_reg,
                              withPrograms = progs' }
          (copyHook simpleUserHooks) pd     lbi_copy userHooks copyFlags
          (regHook simpleUserHooks)  pd_reg lbi_reg  userHooks registerFlags
          return ()

replaceTopdir :: FilePath -> FilePath -> FilePath
replaceTopdir topdir ('$':'t':'o':'p':'d':'i':'r':p) = topdir ++ p
replaceTopdir topdir ('$':'h':'t':'t':'p':'t':'o':'p':'d':'i':'r':p)
    = topdir ++ p
replaceTopdir _ p = p

-- Get the build info, merging the setup-config and buildinfo files.
getConfig :: Verbosity -> FilePath -> IO LocalBuildInfo
getConfig verbosity distPref = do
    lbi <- getPersistBuildConfig distPref
    maybe_infoFile <- defaultHookedPackageDesc
    case maybe_infoFile of
        Nothing -> return lbi
        Just infoFile -> do
            hbi <- readHookedBuildInfo verbosity infoFile
            return lbi { localPkgDescr = updatePackageDescription hbi (localPkgDescr lbi)}


