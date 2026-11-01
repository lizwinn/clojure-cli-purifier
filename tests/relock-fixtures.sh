#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Relocks every test fixture with the clojure-cli-purifier command of this
# checkout. Each fixture keeps the build and test commands and the source
# root of its lockfile. It needs the network, and it runs from any
# directory.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cli=$(nix build --no-link --print-out-paths "$root#cli")

find "$root/tests/fixtures" -name clojure-cli-purifier.lock.json -printf '%h\n' | sort |
  while IFS= read -r project; do
    echo "== $project"
    (cd "$project" && "$cli/bin/clojure-cli-purifier" lock --force)
  done
