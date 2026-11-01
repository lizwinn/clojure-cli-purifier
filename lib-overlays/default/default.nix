# SPDX-License-Identifier: MIT
#
# The `clojure-cli-purifier` library namespace, which holds the builder and
# the lockfile reader of the purifier contract:
#
#   lib.clojure-cli-purifier.buildClojureCliProject {
#     pkgs, src, fetchers ? { }, lockFile ? <src>/clojure-cli-purifier.lock.json, ...
#   }
#   lib.clojure-cli-purifier.readLock { src, projectDir ? ".", lockFile ? ... }
#
# nix/lib/build-clojure-cli-project.nix and nix/lib/read-lock.nix list
# their arguments and their results.
# The builder fetches with the shared purifier library, which this flake
# lists in its `projects`, so this library has `lib.purifier`.
{ ... }:
{

  overlay = final: prev: {
    clojure-cli-purifier = (prev.clojure-cli-purifier or { }) // {
      readLock = import ../../nix/lib/read-lock.nix;
      buildClojureCliProject =
        args@{ pkgs, ... }:
        (pkgs.callPackage ../../nix/lib/build-clojure-cli-project.nix { inherit (final) purifier; }) (
          removeAttrs args [ "pkgs" ]
        );
    };
  };

}
