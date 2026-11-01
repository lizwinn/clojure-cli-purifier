# SPDX-License-Identifier: MIT
#
# Reads a clojure-cli-purifier lockfile, which `clojure-cli-purifier lock`
# writes at the project root, next to deps.edn, and checks its format and
# fields.
#
# It needs no nixpkgs, so the builder and the interactive mode read the
# lockfile the same way.
{ lockFile }:
let
  lock = builtins.fromJSON (builtins.readFile lockFile);

  supportedVersion = import ./lock-version.nix;

  # The fields the builder reads. A lockfile without one was edited or cut
  # short after the lock run wrote it.
  requiredFields = [
    "clojureVersion"
    "javaVersion"
    "definitionFiles"
    "definitionHash"
    "prepared"
    "build"
    "test"
    "project"
    "pom"
    "outputs"
    "artifacts"
    "metadata"
    "git"
    "gitRepos"
  ];
  missingFields = builtins.filter (field: !(builtins.hasAttr field lock)) requiredFields;
in
assert
  builtins.isAttrs lock && lock ? version
  || throw "clojure-cli-purifier: ${toString lockFile} is not a clojure-cli-purifier lockfile. Run `clojure-cli-purifier lock --force` in the project to write it again.";
assert
  lock.version == supportedVersion
  || throw "clojure-cli-purifier: ${toString lockFile} has lock format version ${toString lock.version}, and this library reads version ${toString supportedVersion}. Run `clojure-cli-purifier lock --force` with the clojure-cli-purifier revision that provides this library.";
assert
  missingFields == [ ]
  || throw "clojure-cli-purifier: ${toString lockFile} has no ${builtins.concatStringsSep ", " missingFields}, so it was edited or cut short after the lock run. Run `clojure-cli-purifier lock --force` in the project to write it again.";
lock
