# SPDX-License-Identifier: MIT
# Installable native command; the CLI keeps its own unwrapped Clojure.
{
  lib,
  writeShellApplication,
  coreutils,
  jq,
  cli,
}:
writeShellApplication {
  name = "clojure";
  runtimeInputs = [
    coreutils
    jq
  ];
  text = ''
    root="$PWD"
    while [ ! -f "$root/deps.edn" ] && [ "$root" != / ]; do
      root=$(dirname "$root")
    done
    lock="''${CLOJURE_CLI_PURIFIER_LOCKFILE:-$root/clojure-cli-purifier.lock.json}"
    if [ "''${CLOJURE_CLI_PURIFIER:-1}" = 0 ]; then
      exec ${lib.getExe cli.clojure} "$@"
    fi
    if [ ! -e "$lock" ]; then
      echo "clojure-cli-purifier: warning: no clojure-cli-purifier.lock.json found; running clojure impurely. Run \`clojure-cli-purifier lock\` to use Nix-resolved dependencies." >&2
      exec ${lib.getExe cli.clojure} "$@"
    fi
    lock=$(realpath "$lock")
    state="$(dirname "$lock")/.clojure-cli-purifier"
    checksum=$(jq -er .contentHash "$lock") || {
      echo "clojure-cli-purifier: invalid lockfile; run clojure-cli-purifier lock" >&2
      exit 1
    }
    if [ ! -x "$state/bin/clojure" ] || [ "$(cat "$state/prefetched" 2>/dev/null || true)" != "$checksum" ]; then
      (cd "$root" && ${lib.getExe cli} prefetch --lockfile "$lock")
    fi
    exec "$state/bin/clojure" "$@"
  '';
}
