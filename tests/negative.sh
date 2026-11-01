#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Checks the common mistakes on a copy of the hello fixture, each with the
# message it gives:
#
#   - a lockfile whose hash of a file was changed fails the fetch of that
#     file, and Nix names the file and both hashes;
#   - a lockfile that lacks a download fails the build, with a message to
#     relock;
#   - a lockfile that is not JSON fails the evaluation, naming the file;
#   - a project edited after locking makes `clojure-cli-purifier clojure`
#     warn that the lockfile is out of date.
#
# The Nix builds run the builder outside the flake's checks, because each
# of them is expected to fail. It runs from any directory.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cli=$(nix build --no-link --print-out-paths "$root#cli")/bin/clojure-cli-purifier
jq=$(nix build --no-link --print-out-paths --inputs-from "$root" 'nixpkgs#jq^bin')/bin/jq
work=$(mktemp -d "${TMPDIR:-/tmp}/clojure-cli-purifier-negative.XXXXXX")
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
# Builds an attribute of buildClojureCliProject for the hello copy with a
# lockfile, and prints what Nix reports. It fails when the build succeeds.
# The builder comes from the overlay of the flake, as a consumer gets it.
buildFails() {
  local lockFile=$1 attr=$2 output
  if output=$(nix build --no-link --impure --expr "
    let
      flake = builtins.getFlake \"path:$root\";
      pkgs = import flake.inputs.nixpkgs {
        system = builtins.currentSystem;
        overlays = [ flake.overlays.default ];
      };
    in
    (pkgs.buildClojureCliProject { src = /. + \"$work/hello\"; lockFile = /. + \"$lockFile\"; }).$attr" 2>&1); then
    echo "the build with $lockFile succeeded" >&2
    return 1
  fi
  echo "$output"
}

cp -r "$root/tests/fixtures/hello" "$work/hello"
lock="$work/hello/clojure-cli-purifier.lock.json"
jar=org/clojure/data.json/2.5.1/data.json-2.5.1.jar

echo "== a changed hash fails the fetch of that file"
# shellcheck disable=SC2016 # $jar is a jq variable
"$jq" --arg jar "$jar" '(.artifacts[] | select(.path == $jar) | .hash) = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="' \
  "$lock" >"$work/tampered.json"
buildFails "$work/tampered.json" repository | tee "$work/tampered.log" | tail -5
grep -q 'hash mismatch' "$work/tampered.log"
grep -q 'data.json-2.5.1.jar' "$work/tampered.log"

echo "== a missing download fails the build with a message to relock"
# shellcheck disable=SC2016 # $jar is a jq variable
"$jq" --arg jar "$jar" 'del(.artifacts[] | select(.path == $jar))' "$lock" >"$work/missing.json"
buildFails "$work/missing.json" package | tee "$work/missing.log" | tail -5
grep -q 'Run clojure-cli-purifier lock --force' "$work/missing.log"

echo "== a lockfile that is not JSON fails the evaluation"
printf '{ "version": 1, ' >"$work/broken.json"
buildFails "$work/broken.json" package | tee "$work/broken.log" | tail -5
grep -q 'broken.json' "$work/broken.log"

echo "== a project edited after locking makes the interactive mode warn"
(
  cd "$work/hello"
  export CLJ_CONFIG="$work/config"
  echo ';; edited' >>deps.edn
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
  "$cli" clojure -M:test 2>&1 | tee "$work/stale.log" | head -3 || true
)
grep -q 'is out of date' "$work/stale.log"

echo "== all negative checks passed"
