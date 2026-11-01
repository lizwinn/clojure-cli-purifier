# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.clojure-cli-purifier` (the command is `.cli`), and the builder
# `pkgs.buildClojureCliProject` (nix/lib/build-clojure-cli-project.nix)
# beside them, where nixpkgs keeps its own builders. The builder is a
# package for callPackage, so a package takes it by name, and
# `buildClojureCliProject.override` replaces what it takes from the package
# set. A consumer that lists this flake in `projects` holds the overlay as
# `clojure-cli-purifier/default`, which its package sets apply by default.
#
# The builder and the command fetch with the shared purifier library, which
# this flake lists in its `projects`. The overlay passes that library to
# both.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "clojure-cli-purifier";
in
{
  overlay =
    final: prev:
    let
      added = packages final prev;
    in
    added
    // {
      clojure-cli-purifier = added.clojure-cli-purifier // {
        cli = added.clojure-cli-purifier.cli.override { inherit (closure-lib) purifier; };
      };
      buildClojureCliProject = final.callPackage ../../nix/lib/build-clojure-cli-project.nix {
        inherit (closure-lib) purifier;
      };
    };
}
