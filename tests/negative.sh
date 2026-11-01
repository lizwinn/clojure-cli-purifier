#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Checks the messages that Nix prints when the builder refuses a lockfile
# at evaluation. A check in the sandbox sees only that evaluation failed,
# so this script reads the messages from `nix build`:
#
#   - a lockfile cut short names `clojure-cli-purifier lock --force`;
#   - a lockfile edited after the lock run names `clojure-cli-purifier lock
#     --force`;
#   - a project edited after locking names `clojure-cli-purifier lock`.
#
# The flake's conformance checks cover the messages of the command and of
# the build. It runs from any directory.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
jq=$(nix build --no-link --print-out-paths --inputs-from "$root" 'nixpkgs#jq^bin')/bin/jq
work=$(mktemp -d "${TMPDIR:-/tmp}/clojure-cli-purifier-negative.XXXXXX")
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT

# Evaluates the hello package of the copy with a lockfile, and prints what
# Nix reports. It fails when evaluation succeeds.
evalFails() {
  local lockFile=$1 output
  if output=$(nix eval --raw --impure --expr "
    let
      flake = builtins.getFlake \"git+file://$root\";
      pkgs = import flake.inputs.nixpkgs {
        system = builtins.currentSystem;
        overlays = [ flake.overlays.default ];
      };
    in
    (pkgs.buildClojureCliProject {
      src = /. + \"$work/hello\";
      lockFile = /. + \"$lockFile\";
    }).packages.hello.drvPath" 2>&1); then
    echo "evaluation with $lockFile succeeded" >&2
    return 1
  fi
  echo "$output"
}

cp -r "$root/tests/fixtures/hello" "$work/hello"
chmod -R u+w "$work/hello"
lock="$work/hello/clojure-cli-purifier.lock.json"

echo "== a lockfile cut short names clojure-cli-purifier lock --force"
printf '{ "version": 2, ' >"$work/broken.json"
evalFails "$work/broken.json" | tee "$work/broken.log" | tail -3
grep -q 'broken.json is not a JSON object.*clojure-cli-purifier lock --force' "$work/broken.log"

echo "== an edited lockfile names clojure-cli-purifier lock --force"
"$jq" '.artifacts[0].hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="' "$lock" >"$work/tampered.json"
evalFails "$work/tampered.json" | tee "$work/tampered.log" | tail -3
grep -q 'does not match its contentHash.*clojure-cli-purifier lock --force' "$work/tampered.log"

echo "== an edited project names clojure-cli-purifier lock"
echo ';; edited' >>"$work/hello/deps.edn"
evalFails "$lock" | tee "$work/stale.log" | tail -3
grep -q 'changed after .*clojure-cli-purifier lock' "$work/stale.log"

echo "== all negative checks passed"
