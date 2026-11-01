# SPDX-License-Identifier: MIT
#
# buildClojureCliProject: the sandboxed build of a deps.edn project, from
# the lockfile `clojure-cli-purifier lock` writes at the project root.
#
# The file is a package for callPackage: the first argument set is what it
# takes from the package set, and the result is the builder. The
# clojure-cli-purifier overlay (`overlays.default`) adds it to the package
# set as `buildClojureCliProject`, so a package written for callPackage
# takes it like any other dependency:
#
#   { buildClojureCliProject }: (buildClojureCliProject { src = ./.; }).package
#
# and `buildClojureCliProject.override` replaces what it takes from the
# set. The builder returns
#
#   repository       the local Maven repository of the lock
#   gitlibs          the gitlibs directory of the lock
#   package          the project's outputs in share/java, its POM there
#                    when the build writes one, and a launcher in bin for
#                    each output jar with a main class
#   packages.<name>  the same package, under the project's name
#   lock             the lockfile, as lock.nix reads it
#   jdk              the JDK the build runs on
#   clojure          the Clojure CLI the build runs
{
  lib,
  stdenvNoCC,
  callPackage,
  makeWrapper,
  git,
  # The JDKs a build can run on. The default JDK of a build is the headless
  # one of the major version its lock was made with.
  javaPackages,
  clojure,
  # The functions of the shared purifier library, which fetches the locked
  # downloads. The overlay passes them.
  purifier,
}:
{
  # The source root: the project root, or the directory given to
  # `clojure-cli-purifier lock --source`, which holds the project and its
  # local dependencies.
  src,
  # The directory of the project, which holds deps.edn, relative to `src`.
  projectDir ? ".",
  # The lockfile. The default is the one `clojure-cli-purifier lock` writes
  # at the project root.
  lockFile ?
    src + (if projectDir == "." then "" else "/${projectDir}") + "/clojure-cli-purifier.lock.json",
  # The JDK that runs the Clojure CLI and the project's JVMs.
  jdk ? null,
  # Replaces nixpkgs' fetchurl for the Maven files, for credentials or a
  # mirror. It takes the arguments of nixpkgs' fetchurl.
  fetchurl ? null,
  # Replaces nixpkgs' fetchgit for the git dependencies, such as for a
  # private repository. It takes the arguments of nixpkgs' fetchgit.
  # builtins.fetchGit fetches at evaluation time with the ssh agent and git
  # configuration of the user, and still checks the locked hash:
  #
  #   fetchgit = args: builtins.fetchGit {
  #     inherit (args) url rev;
  #     narHash = args.hash;
  #   };
  fetchgit ? null,
  # Runs the test commands of the lock after the build.
  doCheck ? false,
  # Filters the project root before it is copied into the store, as the
  # `filter` of builtins.path. The default leaves out build outputs and
  # editor state.
  srcFilter ? null,
}:
let
  lock = import ./lock.nix { inherit lockFile; };
  lockProjectDir = lock.projectDir or ".";

  # The lock records the hash of the files that decide what the project
  # resolves: deps.edn, the deps.edn of each local dependency, and the
  # build script. A project whose definition changed after locking would
  # resolve downloads the lock does not hold, so the build stops before it
  # starts.
  definitionHash = builtins.hashString "sha256" (
    lib.concatMapStrings (
      file:
      let
        path = src + "/${file}";
      in
      if builtins.pathExists path then builtins.readFile path else ""
    ) lock.definitionFiles
  );

  defaultSrcFilter =
    path: type:
    let
      name = baseNameOf path;
    in
    !(
      (
        type == "directory"
        && (name == "target" || name == ".cpcache" || name == ".lsp" || name == ".clj-kondo")
      )
      || name == ".git"
      || name == ".idea"
      || name == ".nrepl-port"
      || lib.hasPrefix "result" name
    );

  # The unpack phase copies the source to a directory of this name.
  srcName = "clojure-source";
  filteredSrc = builtins.path {
    path = src;
    name = srcName;
    filter = if srcFilter != null then srcFilter else defaultSrcFilter;
  };

  javaMajor = builtins.head (lib.splitString "." lock.javaVersion);
  defaultJdk =
    javaPackages.compiler."openjdk${javaMajor}".headless
      or (throw "clojure-cli-purifier: javaPackages has no openjdk${javaMajor} for the Java ${lock.javaVersion} the lock was made with; pass `jdk`.");
  jdk' = if jdk != null then jdk else defaultJdk;
  clojure' = clojure.override { jdk = jdk'; };

  repository = callPackage ./repository.nix {
    inherit lockFile purifier;
    fetchurlOverride = fetchurl;
  };
  gitlibs = callPackage ./gitlibs.nix {
    inherit lockFile purifier;
    fetchgitOverride = fetchgit;
  };

  project = lock.project;

  clojureCommands = lib.concatMapStringsSep "\n" (
    args: "purifierClojure ${lib.escapeShellArgs args}"
  );

  javaDirectory = "share/java";
  outputFile = package: output: "${package}/${javaDirectory}/${baseNameOf output.path}";

  launchers = builtins.filter (output: output.mainClass != null) lock.outputs;
  # One launcher takes the project's name, and several take the names of
  # their jars.
  launcherName =
    output:
    if builtins.length launchers == 1 then
      project.name
    else
      lib.removeSuffix ".jar" (baseNameOf output.path);

  package = stdenvNoCC.mkDerivation (finalAttrs: {
    pname = project.name;
    version = if project.version != null then project.version else "0";
    src = filteredSrc;
    # The build runs in the project directory of the source root.
    sourceRoot = srcName + lib.optionalString (projectDir != ".") "/${projectDir}";
    nativeBuildInputs = [
      jdk'
      clojure'
      git
    ]
    ++ lib.optional (launchers != [ ]) makeWrapper;
    dontConfigure = true;
    inherit doCheck;

    # `clojure-cli-purifier lock` runs the Clojure CLI the same way, so a
    # lock made with it holds what this needs: the local repository and the
    # gitlibs directory hold every download, and no user configuration
    # applies. The JVMs find the repository through user.home, which HOME
    # does not set.
    preBuild = ''
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME/.m2/repository" "$TMPDIR/config" "$TMPDIR/java-tmp"
      cp -rs --no-preserve=mode ${repository}/. "$HOME/.m2/repository"
      # Maven Resolver rewrites the metadata records it reads, so those are
      # writable copies.
      find "$HOME/.m2/repository" -type l \( -name 'maven-metadata*.xml' -o -name resolver-status.properties \) \
        -exec cp --remove-destination --no-preserve=mode -L {} {}.tmp \; -exec mv {}.tmp {} \;
      export GITLIBS="$TMPDIR/gitlibs"
      mkdir -p "$GITLIBS"
      # A git dependency that needs preparing is prepared in its checkout,
      # so the checkouts are writable copies.
      cp -rL --no-preserve=mode ${gitlibs}/. "$GITLIBS"
      echo '{}' >"$TMPDIR/config/deps.edn"
      export CLJ_CONFIG="$TMPDIR/config"
      export CLJ_CACHE="$TMPDIR/cpcache"
      export CLJ_JVM_OPTS="-Duser.home=$HOME -Djava.io.tmpdir=$TMPDIR/java-tmp"
      export JAVA_OPTS="$CLJ_JVM_OPTS"
      export JAVA_CMD=${jdk'}/bin/java
      export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
      # Runs the Clojure CLI. When it fails to resolve a download, the
      # lockfile lacks that download, and the message says how to renew it.
      purifierClojure() {
        if clojure "$@" > >(tee "$TMPDIR/clojure.log") 2>&1; then
          return 0
        fi
        if grep -qE 'could not be resolved|Could not transfer|Could not find artifact|Unable to clone|Network is unreachable' "$TMPDIR/clojure.log"; then
          echo "clojure-cli-purifier: the Clojure CLI tried to download something ${toString lockFile} does not hold. Run clojure-cli-purifier lock --force in the project, which records every download again." >&2
        fi
        return 1
      }
      # Git dependencies that need preparing are prepared for the aliases
      # the lock prepared, as the lock run did.
      purifierClojure -X:deps prep :aliases ${lib.escapeShellArg "[${lib.concatStringsSep " " lock.prepared}]"}
    '';
    buildPhase = ''
      runHook preBuild
      ${clojureCommands lock.build}
      runHook postBuild
    '';
    checkPhase = ''
      runHook preCheck
      ${clojureCommands lock.test}
      runHook postCheck
    '';
    dontFixup = launchers == [ ];
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/${javaDirectory}"
      for output in ${lib.escapeShellArgs (map (output: output.path) lock.outputs)}; do
        if [ ! -f "$output" ]; then
          echo "clojure-cli-purifier: the lock names $output, which this build of ${project.name} did not produce; run clojure-cli-purifier lock --force" >&2
          exit 1
        fi
        cp "$output" "$out/${javaDirectory}/"
      done
      ${lib.optionalString (lock.pom != null) ''
        cp ${lib.escapeShellArg lock.pom} "$out/${javaDirectory}/${project.name}-${project.version}.pom"
      ''}
      ${lib.concatMapStrings (output: ''
        makeWrapper ${jdk'}/bin/java "$out/bin/${launcherName output}" \
          --add-flags "-jar $out/${javaDirectory}/${baseNameOf output.path}"
      '') launchers}
      runHook postInstall
    '';
    passthru = {
      inherit repository gitlibs lock;
      jdk = jdk';
      clojure = clojure';
      # The files of the package by file name, such as
      # artifacts."hello-1.0.0-standalone.jar". They are known from the
      # lock alone, before the package is built.
      artifacts =
        builtins.listToAttrs (
          map (output: {
            name = baseNameOf output.path;
            value = outputFile finalAttrs.finalPackage output;
          }) lock.outputs
        )
        // lib.optionalAttrs (lock.pom != null) {
          "${project.name}-${project.version}.pom" =
            "${finalAttrs.finalPackage}/${javaDirectory}/${project.name}-${project.version}.pom";
        };
    };
    meta = {
      description = "${project.group}/${project.name}, built by clojure-cli-purifier";
    }
    // lib.optionalAttrs (launchers != [ ]) { mainProgram = launcherName (builtins.head launchers); };
  });
in
assert
  lockProjectDir == projectDir
  || throw "clojure-cli-purifier: ${toString lockFile} was made for the project directory ${lockProjectDir} of its source root, and buildClojureCliProject has projectDir ${projectDir}; pass projectDir = \"${lockProjectDir}\".";
assert
  definitionHash == lock.definitionHash
  || throw "clojure-cli-purifier: the project definition in ${toString src} (${lib.concatStringsSep ", " lock.definitionFiles}) changed after ${toString lockFile} was made; run `clojure-cli-purifier lock`.";
assert
  clojure'.version == lock.clojureVersion
  || throw "clojure-cli-purifier: the lock was made with Clojure CLI ${lock.clojureVersion}, and this package set has Clojure CLI ${clojure'.version}. Re-lock with the clojure-cli-purifier of this package set, or pass a `clojure` of version ${lock.clojureVersion} through buildClojureCliProject.override.";
{
  inherit
    lock
    repository
    gitlibs
    package
    ;
  packages.${project.name} = package;
  jdk = jdk';
  clojure = clojure';
}
