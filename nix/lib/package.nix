# SPDX-License-Identifier: MIT
#
# What `clojure-cli-purifier publish` builds: the package of the project at
# `projectDir` of the source root `src`, with the nixpkgs source the
# clojure-cli-purifier command was built with. All three arguments are
# strings: `src` and `nixpkgs` are the absolute paths the command passes.
{
  nixpkgs,
  src,
  projectDir,
}:
let
  pkgs = import nixpkgs { };
  build = pkgs.callPackage ./build-clojure-cli-project.nix { };
in
(build {
  src = builtins.path {
    path = /. + src;
    name = "clojure-source";
  };
  inherit projectDir;
}).package
