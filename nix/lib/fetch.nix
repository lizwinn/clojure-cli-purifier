# SPDX-License-Identifier: MIT
#
# The fetchers for locked downloads: one for the files of the Maven
# repository, one for the checkouts of git dependencies.
#
# A file is a fixed-output derivation on nixpkgs' fetchurl, tried at its
# URL and then at each of its mirrors. A fixed-output store path depends
# only on its name and hash, so the interactive mode and the builder share
# every fetched file.
#
# `fetchurl`, when given, replaces nixpkgs' fetchurl. It is called with
# { name, urls, hash } and is the place for credentials (nixpkgs'
# fetchurl takes `netrcPhase`) or a local mirror.
#
# A checkout is nixpkgs' fetchgit at the locked commit, so the lock's hash
# is the one `nix-prefetch-git` reports.
#
# `fetchgitOverride`, when given, replaces nixpkgs' fetchgit. It is called
# with the arguments of fetchgit, and is the place for a repository that
# needs credentials. builtins.fetchGit fetches at evaluation time with the
# ssh agent and git configuration of the user, so
#
#   args: builtins.fetchGit { inherit (args) url rev; narHash = args.hash; }
#
# fetches a private repository and still checks the locked hash.
{
  lock,
  nixpkgsFetchurl,
  fetchgit,
  fetchurl ? null,
  fetchgitOverride ? null,
}:
{
  file =
    artifact:
    (if fetchurl != null then fetchurl else nixpkgsFetchurl) {
      name = lock.artifactName artifact;
      inherit (artifact) hash;
      urls = [ artifact.url ] ++ artifact.mirrors;
    };

  checkout =
    entry:
    (if fetchgitOverride != null then fetchgitOverride else fetchgit) {
      name = lock.checkoutName entry;
      inherit (entry.git) url rev leaveDotGit;
      fetchSubmodules = entry.git.submodules;
      inherit (entry) hash;
    };
}
