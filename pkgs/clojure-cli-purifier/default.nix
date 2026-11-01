# SPDX-License-Identifier: MIT
#
# The clojure-cli-purifier command: `clojure-cli-purifier lock` writes a
# project's lockfile, `clojure-cli-purifier clojure` runs the Clojure CLI
# offline on the locked downloads, and `clojure-cli-purifier publish`
# deploys what Nix built. It calls the nix-build and nix-hash of the Nix
# installation it runs on.
{
  writeShellApplication,
  clojure,
  # The JVM of the Clojure CLI. The lock records its version, and the Nix
  # build runs on a JDK of the same major version.
  jdk_headless,
  git,
  jq,
  unzip,
  gnutar,
  coreutils,
  findutils,
  gnused,
  gnugrep,
  gawk,
  # The nixpkgs source of this package set, which the interactive mode and
  # the publish step build with.
  path,
}:
let
  jdk = jdk_headless;
  clojure' = clojure.override { inherit jdk; };
in
writeShellApplication {
  name = "clojure-cli-purifier";
  runtimeInputs = [
    clojure'
    jdk
    git
    jq
    unzip
    gnutar
    coreutils
    findutils
    gnused
    gnugrep
    gawk
  ];
  runtimeEnv = {
    PURIFIER_LIB = ../../nix/lib;
    PURIFIER_FORMAT = toString (import ../../nix/lib/lock-version.nix);
    PURIFIER_HELPER = ./helper.clj;
    PURIFIER_TOOLS_JAR = "${clojure'}/libexec/clojure-tools-${clojure'.version}.jar";
    PURIFIER_NIXPKGS = "${path}";
  };
  text = ''
    export JAVA_CMD=''${JAVA_CMD:-${jdk}/bin/java}
  ''
  + builtins.readFile ./clojure-cli-purifier.sh;
  passthru = {
    inherit jdk;
    clojure = clojure';
  };
}
