# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.clojure-cli-purifier`: the command is `.cli`. A consumer that lists
# this flake in `projects` holds it as `clojure-cli-purifier/default`, which
# its package sets apply by default.
#
# The command builds its deploy tool with the shared purifier library. A
# consumer's package set has no `lib.purifier`, so the overlay passes the
# library of this flake to the command.
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
    };
}
