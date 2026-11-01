# SPDX-License-Identifier: MIT
#
# What `clojure-cli-purifier publish` builds: the package of the project at
# `projectDir` of the source root `src`, with the nixpkgs source and the
# shared purifier library the clojure-cli-purifier command was built with.
# All four arguments are strings: `src` and `nixpkgs` are absolute paths,
# and `purifierRef` is a locked flake reference.
{
  nixpkgs,
  purifierRef,
  src,
  projectDir,
}:
let
  pkgs = import nixpkgs { };
  inherit ((builtins.getFlake purifierRef).lib) purifier;
  build = pkgs.callPackage ./build-clojure-cli-project.nix { inherit purifier; };
in
(build {
  src = builtins.path {
    path = /. + src;
    name = "clojure-source";
  };
  inherit projectDir;
}).package
