# SPDX-License-Identifier: MIT
#
# What `clojure-cli-purifier clojure` builds for an interactive Clojure
# CLI: one store path that holds the local Maven repository of the lock
# (`repository`) and its gitlibs directory (`gitlibs`). The command keeps
# a GC root on it, so the locked downloads stay in the store while the
# project uses them.
#
# `nixpkgs` is the nixpkgs source the clojure-cli-purifier command was
# built with, and `purifierRef` the locked flake reference of the shared
# purifier library it was built with, both as strings. So the interactive
# mode fetches the same way the builder does, and the two share every store
# path.
{
  lockFile,
  nixpkgs,
  purifierRef,
}:
let
  pkgs = import nixpkgs { };
  inherit ((builtins.getFlake purifierRef).lib) purifier;
  repository = pkgs.callPackage ./repository.nix { inherit lockFile purifier; };
  gitlibs = pkgs.callPackage ./gitlibs.nix { inherit lockFile purifier; };
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
