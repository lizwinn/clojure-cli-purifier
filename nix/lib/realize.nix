# SPDX-License-Identifier: MIT
#
# What `clojure-cli-purifier clojure` builds for an interactive Clojure
# CLI: one store path that holds the local Maven repository of the lock
# (`repository`) and its gitlibs directory (`gitlibs`). The command keeps
# a GC root on it, so the locked downloads stay in the store while the
# project uses them.
#
# `nixpkgs` is the nixpkgs source the clojure-cli-purifier command was
# built with, as a string, so the interactive mode fetches with the same
# fetchurl and fetchgit as the builder, and the two share every store path.
{ lockFile, nixpkgs }:
let
  pkgs = import nixpkgs { };
  repository = pkgs.callPackage ./repository.nix { inherit lockFile; };
  gitlibs = pkgs.callPackage ./gitlibs.nix { inherit lockFile; };
in
pkgs.runCommand "clojure-cli-purifier-env"
  {
    preferLocalBuild = true;
    allowSubstitutes = false;
  }
  ''
    mkdir -p $out
    ln -s ${repository} $out/repository
    ln -s ${gitlibs} $out/gitlibs
  ''
