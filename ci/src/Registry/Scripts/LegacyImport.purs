module Registry.Scripts.LegacyImport where

import Registry.Prelude

import Control.Monad.Except as Except
import Data.Array as Array
import Data.Array.NonEmpty as NEA
import Data.Map as Map
import Data.Set as Set
import Data.String as String
import Data.Time.Duration (Hours(..))
import Dotenv as Dotenv
import Effect.Aff as Aff
import Effect.Ref as Ref
import Foreign.GitHub as GitHub
import Foreign.Object as Object
import Registry.API as API
import Registry.Index (RegistryIndex)
import Registry.Json as Json
import Registry.PackageGraph as Graph
import Registry.PackageName (PackageName)
import Registry.PackageName as PackageName
import Registry.PackageUpload as Upload
import Registry.RegistryM (Env, runRegistryM)
import Registry.Schema (Manifest(..), Metadata, Operation(..), Repo(..))
import Registry.Scripts.LegacyImport.Error (APIResource(..), ImportError(..), ManifestError(..), PackageFailures(..), RemoteResource(..), RequestError(..))
import Registry.Scripts.LegacyImport.Manifest as Manifest
import Registry.Scripts.LegacyImport.Process as Process
import Registry.Scripts.LegacyImport.Stats as Stats
import Registry.Types (RawPackageName(..), RawVersion(..))
import Registry.Version (ParseMode(..), Version)
import Registry.Version as Version
import Safe.Coerce (coerce)
import Text.Parsing.StringParser as StringParser

-- | This main loop uploads legacy packages to the new Registry
-- | In order to do this, we:
-- | - get an index of the legacy packages
-- | - create a graph (a tree really) where a package is a node and dependencies are edges
-- | - topologically sort this graph so that packages with no dependencies are at the root
-- | - go through this list: if the package is in the registry index then skip, otherwise upload
main :: Effect Unit
main = Aff.launchAff_ do
  _ <- Dotenv.loadFile

  API.checkIndexExists

  log "Starting import from legacy registries..."
  registry <- downloadLegacyRegistry

  log "Temporary: we filter packages to only deal with the ones in core and other orgs we control"
  let
    sortedPackages = Graph.topologicalSort registry
    isCorePackage (Manifest manifest) = case manifest.repository of
      -- core
      GitHub { owner: "purescript" } -> Just manifest
      GitHub { owner: "purescript-deprecated" } -> Just manifest
      -- contrib
      GitHub { owner: "purescript-contrib" } -> Just manifest
      GitHub { owner: "purescript-web" } -> Just manifest
      GitHub { owner: "purescript-node" } -> Just manifest
      GitHub { repo: "purescript-void" } -> Just manifest
      GitHub { repo: "purescript-index" } -> Just manifest
      GitHub { repo: "purescript-optic" } -> Just manifest
      GitHub { repo: "purescript-unordered-collections" } -> Just manifest
      GitHub { repo: "purescript-text-encoding" } -> Just manifest
      GitHub { repo: "purescript-typelevel" } -> Just manifest
      GitHub { repo: "purescript-sized-vectors" } -> Just manifest
      GitHub { repo: "purescript-nonempty-array" } -> Just manifest
      GitHub { repo: "purescript-colors" } -> Just manifest
      GitHub { repo: "purescript-eff-functions" } -> Just manifest
      GitHub { repo: "purescript-node-events" } -> Just manifest
      GitHub { repo: "purescript-nonempty-array" } -> Just manifest
      GitHub { repo: "purescript-aff-promise" } -> Just manifest
      GitHub { repo: "purescript-naturals" } -> Just manifest
      _ -> Nothing
    corePackages = Array.mapMaybe isCorePackage sortedPackages

  log "Creating a Metadata Ref"
  packagesMetadataRef <- API.mkMetadataRef

  log "Filtering out packages we already uploaded"
  packagesMetadata <- liftEffect $ Ref.read packagesMetadataRef
  let
    wasPackageUploaded { name, version } = API.isPackageVersionInMetadata name version packagesMetadata
    packagesToUpload = Array.filter (not wasPackageUploaded) corePackages

  log "Starting upload..."
  void $ for packagesToUpload \manifest -> do
    let
      addition = Addition
        { addToPackageSet: false -- heh, we don't have package sets until we do this import!
        , legacy: true
        , newPackageLocation: manifest.repository
        , newRef: Version.rawVersion manifest.version
        , packageName: manifest.name
        }
    log "\n\n----------------------------------------------------------------------"
    log $ "UPLOADING PACKAGE: " <> show manifest.name <> " " <> show manifest.version
    logShow addition
    log "----------------------------------------------------------------------"
    runRegistryM (mkEnv packagesMetadataRef) (API.runOperation addition)

  log "Done!"

mkEnv :: Ref (Map PackageName Metadata) -> Env
mkEnv packagesMetadata =
  { comment: \err -> error err
  , closeIssue: log "Skipping GitHub issue closing, we're running locally.."
  , commitToTrunk: \_ _ -> do
      log "Skipping committing to trunk.."
      pure (Right unit)
  , uploadPackage: Upload.upload
  , packagesMetadata
  }

downloadLegacyRegistry :: Aff RegistryIndex
downloadLegacyRegistry = do
  octokit <- liftEffect GitHub.mkOctokit
  bowerPackages <- readRegistryFile "bower-packages.json"
  newPackages <- readRegistryFile "new-packages.json"

  let
    allPackages = Map.union bowerPackages newPackages
    initialPackages = { failures: PackageFailures Map.empty, packages: allPackages }

  log "Fetching package releases..."
  releaseIndex <- Process.forPackage initialPackages \name repoUrl -> do
    address <- case GitHub.parseRepo repoUrl of
      Left err -> throwError $ InvalidGitHubRepo $ StringParser.printParserError err
      Right address -> pure address

    let
      repoCache = Array.fold [ "releases__", address.owner, "__", address.repo ]
      mkError = ResourceError <<< { resource: APIResource GitHubReleases, error: _ }

    releases <- Process.withCache Process.jsonSerializer repoCache (Just $ Hours 24.0) do
      log $ "Fetching releases for package " <> un RawPackageName name
      result <- lift $ try $ GitHub.getReleases octokit address
      case result of
        Left err -> logShow err *> throwError (mkError $ DecodeError $ Aff.message err)
        Right v -> pure v

    versions <- case NEA.fromArray releases of
      Nothing -> throwError $ mkError $ DecodeError "No releases returned from the GitHub API."
      Just arr -> pure $ Map.fromFoldable $ map (\tag -> Tuple (RawVersion tag.name) unit) arr

    pure $ Tuple { name, address } versions

  log "Parsing names and versions..."
  packageRegistry <- Process.forPackageVersionKeys releaseIndex \{ name, address } tag -> do
    packageName <- case PackageName.parse $ un RawPackageName name of
      Left err ->
        throwError $ MalformedPackageName $ StringParser.printParserError err
      Right pname ->
        pure pname

    packageVersion <- case Version.parseVersion Lenient $ un RawVersion tag of
      Left _ ->
        throwError $ ManifestImportError $ NEA.singleton $ BadVersion $ un RawVersion tag
      Right version ->
        pure version

    let
      outerKey = { name: packageName, original: name, address }
      innerKey = { version: packageVersion, original: tag }

    pure $ Tuple outerKey innerKey

  log "Converting to manifests..."
  let forPackageRegistry = Process.forPackageVersion packageRegistry
  manifestRegistry
    :: Process.ProcessedPackageVersions
         { address :: GitHub.Address
         , name :: PackageName
         , original :: RawPackageName
         }
         { version :: Version, original :: RawVersion }
         Manifest <- forPackageRegistry \{ name, original: originalName, address } tag _ -> do
    manifestFields <- Manifest.constructManifestFields originalName tag.original address

    let
      repo = GitHub { owner: address.owner, repo: address.repo, subdir: Nothing }
      liftError = map (lmap ManifestImportError)

    Except.mapExceptT liftError $ Manifest.toManifest name repo tag.version manifestFields

  log "Writing exclusions file..."
  Json.writeJsonFile "./bower-exclusions.json" manifestRegistry.failures
  Stats.logStats $ Stats.errorStats manifestRegistry

  let
    registryIndex :: RegistryIndex
    registryIndex = do
      let
        packageManifests :: Array (Tuple PackageName (Map Version Manifest))
        packageManifests =
          map (lmap _.name)
            $ map (map (Map.fromFoldable <<< map (lmap _.version) <<< (Map.toUnfoldable :: _ -> Array _)))
            $ Map.toUnfoldable manifestRegistry.packages

        -- Many packages are removed altogether during processing. In this step,
        -- we ensure the registry index has every package with a valid package
        -- name included. `Map.fromFoldable` prefers latter keys in the case of
        -- collision, so any package in `packageManifests` will overwrite the
        -- default empty map for the package when the registry index is
        -- constructed.
        emptyPackages :: Array (Tuple PackageName (Map Version Manifest))
        emptyPackages =
          map (\package -> Tuple package Map.empty)
            $ Array.mapMaybe (hush <<< PackageName.parse)
            $ (coerce :: Array RawPackageName -> Array String)
            $ Set.toUnfoldable
            $ Map.keys allPackages

      Map.fromFoldable (emptyPackages <> packageManifests)

  log "Constructing self-contained registry index..."
  let { index: checkedIndex, unsatisfied } = Graph.checkRegistryIndex registryIndex

  unless (Array.null unsatisfied) do
    log "Writing unsatisfied dependencies file..."
    Json.writeJsonFile "./unsatisfied-dependencies.json" unsatisfied

    log (show (Array.length unsatisfied) <> " manifest entries with unsatisfied dependencies")

  pure checkedIndex

-- Packages can be specified either in 'package-name' format or
-- in owner/package-name format. This function ensures we don't pick
-- up owner names as part of package names.
--
-- Example:
-- https://github.com/newlandsvalley/purescript-abc-parser/blob/1.1.2/bower.json
cleanPackageName :: RawPackageName -> ExceptT ImportError Aff RawPackageName
cleanPackageName (RawPackageName name) = do
  let
    split = String.split (String.Pattern "/") <<< coerce
    strip = coerce <<< stripPureScriptPrefix

  map strip $ case split name of
    [ packageName ] -> pure packageName
    [ _owner, repo ] -> pure repo
    _ -> throwError $ MalformedPackageName name

-- | Read the list of packages in a registry file
readRegistryFile :: FilePath -> Aff (Map RawPackageName GitHub.PackageURL)
readRegistryFile source = do
  registryFile <- Json.readJsonFile ("../" <> source)
  case registryFile of
    Left err -> do
      let decodeError = "Decoding " <> source <> "failed with error:\n\n" <> err
      throwError $ Aff.error decodeError
    Right packages -> do
      let toPackagesArray = Object.toArrayWithKey \k -> Tuple (RawPackageName $ stripPureScriptPrefix k)
      pure $ Map.fromFoldable $ toPackagesArray packages
