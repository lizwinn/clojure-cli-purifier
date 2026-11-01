# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked files and checkouts.
{
  pkgs,
  # The flake's default package overlay, which adds buildClojureCliProject.
  overlay,
  # The clojure-cli-purifier command.
  cli,
}:
let
  # Every fixture builds the way a consumer's package does: through
  # buildClojureCliProject of a package set the overlay applies to.
  withOverlay = pkgs.extend overlay;
  inherit (withOverlay) buildClojureCliProject;

  # An application with dependencies from Maven Central and Clojars, a
  # local dependency, git dependencies given by tag and short commit
  # (tools.build and the test runner), a SNAPSHOT and a version range. Its
  # tests run in the build, among them the SNAPSHOT and the version range.
  hello = buildClojureCliProject {
    src = ./fixtures/hello;
    doCheck = true;
  };

  # A copy of the hello lock with some fields changed.
  helloLockWith =
    attrs:
    builtins.toFile "clojure-cli-purifier.lock.json" (
      builtins.toJSON (
        builtins.fromJSON (builtins.readFile ./fixtures/hello/clojure-cli-purifier.lock.json) // attrs
      )
    );

  # Whether buildClojureCliProject refuses the hello project with this
  # lockfile when the package is evaluated.
  refuses =
    lockFile:
    !(builtins.tryEval
      (buildClojureCliProject {
        src = ./fixtures/hello;
        inherit lockFile;
      }).package.drvPath
    ).success;
in
{
  inherit cli;

  hello = hello.package;

  # The launcher runs the uberjar, which holds every dependency and the
  # local one.
  hello-runs = pkgs.runCommand "hello-runs" { } ''
    ${hello.package}/bin/hello > output
    grep -qx '{"hello":"Hello, Nix"}' output
    grep -qx '<p>purified</p>' output
    touch $out
  '';

  # The lock names every file of the package before it is built, and each
  # one is in the package.
  hello-artifacts = pkgs.runCommand "hello-artifacts" { } ''
    test -f ${hello.package.artifacts."hello-1.0.0.jar"}
    test -f ${hello.package.artifacts."hello-1.0.0-standalone.jar"}
    test -f ${hello.package.artifacts."hello-1.0.0.pom"}
    grep -q '<artifactId>hello</artifactId>' ${hello.package.artifacts."hello-1.0.0.pom"}
    touch $out
  '';

  # The rebuilt bare repositories hold the locked commits and their tags,
  # so the Clojure CLI expands a short commit and checks a tag offline.
  hello-gitlibs =
    pkgs.runCommand "hello-gitlibs"
      {
        nativeBuildInputs = [ pkgs.git ];
      }
      ''
        export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
        export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
        repo=${hello.gitlibs}/_repos/https/github.com/cognitect-labs/test-runner
        test "$(git --git-dir=$repo rev-parse dfb30dd^{commit})" = dfb30dd6605cb6c0efc275e1df1736f6e90d4d73
        test "$(git --git-dir=$repo rev-parse v0.5.1^{commit})" = dfb30dd6605cb6c0efc275e1df1736f6e90d4d73
        test -f ${hello.gitlibs}/libs/io.github.clojure/tools.build/deedd623574e3712687a657691c6b79f5026b3a1/deps.edn
        touch $out
      '';

  # An application whose local dependency lies outside its directory, in
  # a source root that holds both. Its test command runs the application,
  # which needs the dependency of the library.
  mono =
    (buildClojureCliProject {
      src = ./fixtures/mono;
      projectDir = "app";
      doCheck = true;
    }).package;

  # A fetchgit replacement fetches the git dependencies, the way a private
  # repository is fetched with the credentials of the user. The rebuilt
  # bare repositories check that each checkout holds its commit.
  hello-fetchgit-override =
    (buildClojureCliProject {
      src = ./fixtures/hello;
      fetchgit =
        args:
        builtins.fetchGit {
          inherit (args) url rev;
          narHash = args.hash;
        };
    }).gitlibs;

  # A lock made from another project definition, with another Clojure CLI
  # or in another format would not hold what the build resolves, so the
  # builder refuses it at evaluation.
  stale-lock-refused =
    assert refuses (helloLockWith {
      definitionHash = "0000";
    });
    assert refuses (helloLockWith {
      clojureVersion = "0.0.0";
    });
    assert refuses (helloLockWith {
      version = 0;
    });
    pkgs.runCommand "stale-lock-refused" { } "touch $out";
}
