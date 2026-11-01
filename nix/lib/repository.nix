# SPDX-License-Identifier: MIT
#
# The local Maven repository of a lockfile. Every locked file sits at its
# path in the repository as a link into the store. Every recorded metadata
# file is written out with the contents the lock holds.
#
# The tree holds no `_remote.repositories` tracking files. Maven Resolver
# treats an artifact without a tracking record as installed locally, so the
# Clojure CLI and tools.build resolve offline from it. The recorded
# `resolver-status.properties` files mark each metadata file as checked in
# the year 2100, so the resolver never asks a remote repository for a newer
# version list.
{
  lib,
  runCommand,
  jq,
  fetchurl,
  fetchgit,
  lockFile,
  # Replaces nixpkgs' fetchurl; see fetch.nix.
  fetchurlOverride ? null,
}:
let
  lock = import ./lock.nix { inherit lockFile; };
  fetch = import ./fetch.nix {
    inherit lock fetchgit;
    nixpkgsFetchurl = fetchurl;
    fetchurl = fetchurlOverride;
  };
in
# The manifest goes to the builder as a file, because a large project locks
# hundreds of files and the list would not fit in an environment variable.
runCommand "clojure-cli-purifier-repository"
  {
    nativeBuildInputs = [ jq ];
    manifest = lib.concatMapStrings (a: "${a.path}\t${fetch.file a}\n") lock.artifacts;
    metadata = builtins.toJSON lock.metadata;
    passAsFile = [
      "manifest"
      "metadata"
    ];
    preferLocalBuild = true;
    allowSubstitutes = false;
    passthru = { inherit lock; };
  }
  ''
    mkdir -p $out
    while IFS=$'\t' read -r rel target; do
      mkdir -p "$out/$(dirname "$rel")"
      ln -s "$target" "$out/$rel"
    done < "$manifestPath"
    count=$(jq length "$metadataPath")
    for ((i = 0; i < count; i++)); do
      rel=$(jq -r --argjson i "$i" '.[$i].path' "$metadataPath")
      mkdir -p "$out/$(dirname "$rel")"
      jq -j --argjson i "$i" '.[$i].contents' "$metadataPath" >"$out/$rel"
    done
  ''
