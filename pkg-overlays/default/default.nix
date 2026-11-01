# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.clojure-cli-purifier` (`.cli`), and the builder
# `pkgs.buildClojureCliProject` (nix/lib/build-clojure-cli-project.nix)
# beside them, where nixpkgs keeps its own builders, so a package written
# for callPackage takes it by name. A consumer that lists this flake in
# `projects` holds it as `clojure-cli-purifier/default`, which its package
# sets apply by default.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "clojure-cli-purifier";
in
{
  overlay =
    final: prev:
    packages final prev
    // {
      buildClojureCliProject = final.callPackage ../../nix/lib/build-clojure-cli-project.nix { };
    };
}
