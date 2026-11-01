# SPDX-License-Identifier: MIT
#
# The local Maven repository of a lockfile: the file entries of the
# downloads and the inline entries of the recorded metadata, laid out by the
# `tree` of the shared purifier library, each a link into the store.
#
# The tree holds no `_remote.repositories` tracking files. Maven Resolver
# treats an artifact without a tracking record as installed locally, so the
# Clojure CLI and tools.build resolve offline from it. The recorded
# `resolver-status.properties` files mark each metadata file as checked in
# the year 2100, so the resolver never asks a remote repository for a newer
# version list.
{
  pkgs,
  lib,
  # The functions of the shared purifier library.
  purifier,
  lockFile,
  # Replaces nixpkgs' fetchurl for the files, for credentials or a mirror.
  fetchurlOverride ? null,
}:
let
  lock = import ./lock.nix { inherit lockFile; };
in
purifier.tree (
  {
    inherit pkgs;
    name = "clojure-cli-purifier-repository";
    entries = lock.artifacts ++ lock.metadata;
  }
  // lib.optionalAttrs (fetchurlOverride != null) { fetchurl = fetchurlOverride; }
)
