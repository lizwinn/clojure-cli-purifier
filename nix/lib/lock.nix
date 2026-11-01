# SPDX-License-Identifier: MIT
#
# Reads a clojure-cli-purifier lockfile, which `clojure-cli-purifier lock`
# writes at the project root, next to deps.edn.
#
# It needs no nixpkgs, so the builder and the interactive mode read the
# lockfile the same way.
{ lockFile }:
let
  lock = builtins.fromJSON (builtins.readFile lockFile);

  supportedVersion = import ./lock-version.nix;

  # A store path name from a file name. Store path names allow
  # [A-Za-z0-9+._?=-], must not start with a dot, and are at most 211
  # characters, so every other character becomes "_". The builder and the
  # interactive mode both name their fetches with this function, so they
  # share store paths.
  storeName =
    fileName:
    let
      # builtins.split alternates the text between matches with a list per
      # match.
      replaced = builtins.concatStringsSep "" (
        map (part: if builtins.isList part then "_" else part) (
          builtins.split "[^A-Za-z0-9+._?=-]" fileName
        )
      );
      undotted = builtins.head (builtins.match "\\.*(.*)" replaced);
      nonEmpty = if undotted == "" then "file" else undotted;
    in
    builtins.substring 0 200 nonEmpty;
in
assert
  lock.version == supportedVersion
  || throw "clojure-cli-purifier: ${toString lockFile} has lock format version ${toString lock.version}, and this library reads version ${toString supportedVersion}. Run `clojure-cli-purifier lock --force` with the clojure-cli-purifier revision that provides this library.";
lock
// {
  inherit storeName;

  # The fetch name of a Maven artifact: its file name, made a valid store
  # name.
  artifactName = artifact: storeName (builtins.baseNameOf artifact.path);

  # The fetch name of a git checkout: the library directory and the commit,
  # such as "tools.build-deedd623574e".
  checkoutName =
    entry:
    storeName "${builtins.baseNameOf (builtins.dirOf entry.path)}-${
      builtins.substring 0 12 entry.git.rev
    }";
}
