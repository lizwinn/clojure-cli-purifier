#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Checks the commands that run outside the Nix sandbox, on a copy of the
# hello fixture:
#
#   - `clojure-cli-purifier lock` leaves an up-to-date lockfile as it is;
#   - after `clojure-cli-purifier prefetch`, `clojure` runs the tests, the
#     SNAPSHOT and the version range aliases, and the uberjar build with no
#     network access, from the locked downloads alone;
#   - a lockfile kept outside the project works through --lockfile and
#     CLOJURE_CLI_PURIFIER_LOCKFILE;
#   - `clojure-cli-purifier publish` deploys the jar and POM that Nix built
#     to a file repository.
#
# The publish step downloads its deploy tool, so it needs the network. The
# offline steps unset the proxy variables, which in a sandbox without
# direct network access cuts the JVMs off. It runs from any directory.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cli=$(nix build --no-link --print-out-paths "$root#cli")/bin/clojure-cli-purifier
wrapper=$(nix build --no-link --print-out-paths "$root#clojure")/bin/clojure
java=$(nix build --no-link --print-out-paths "$root#cli.jdk")/bin/java
jq=$(nix build --no-link --print-out-paths --inputs-from "$root" 'nixpkgs#jq^bin')/bin/jq
work=$(mktemp -d "${TMPDIR:-/tmp}/clojure-cli-purifier-interactive.XXXXXX")
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
# The JVMs write their temporary files under the work directory.
export JAVA_TOOL_OPTIONS="-Djava.io.tmpdir=$work"
cp -r "$root/tests/fixtures/hello" "$work/hello"
cd "$work/hello"
# The Clojure CLI creates its user configuration on first use, so the test
# gives it one of its own.
export CLJ_CONFIG="$work/config"
# Every lock run downloads Maven Central's files from Google's mirror of
# it, as the fixtures were locked.
mirror=central=https://maven-central.storage-download.googleapis.com/maven2/

echo "== the installed wrapper works outside a configured project"
(cd "$work" && "$wrapper" -Sdescribe >"$work/unlocked.out" 2>"$work/unlocked.log")
grep -q 'warning:.*impurely' "$work/unlocked.log"
grep -q ':version' "$work/unlocked.out"

echo "== lock leaves an up-to-date lockfile alone"
"$cli" lock | grep -q 'is up to date'

echo "== the installed wrapper prepares and uses a locked project"
"$wrapper" -M:test | grep -q '0 failures, 0 errors'

echo "== after prefetch, clojure runs offline from the locked downloads"
"$cli" prefetch
test -L .clojure-cli-purifier/env
(
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
  export PATH="$PWD/.clojure-cli-purifier/bin:$PATH"
  clojure -M:test | grep -q '0 failures, 0 errors'
  clojure -M:snapshot | grep -qx '<b>snapshot</b>'
  clojure -M:range | grep -qx 'range 49'
  clojure -T:build uber
  "$java" -jar target/hello-1.0.0-standalone.jar | grep -qx '<p>purified</p>'
)

echo "== publish deploys what Nix built"
built=$("$cli" publish --dry-run | sed -n 's/^jar: //p')
test -f "$built"
mkdir -p "$work/repository"
# The deploy tool runs from the package, so publishing to a file
# repository needs no network.
(
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
  # deps-deploy keeps a local Maven repository under user.home.
  export JAVA_TOOL_OPTIONS="$JAVA_TOOL_OPTIONS -Duser.home=$work/publish-home"
  mkdir -p "$work/publish-home"
  "$cli" publish --repository "local=file://$work/repository"
)
cmp "$built" "$work/repository/example/hello/1.0.0/hello-1.0.0.jar"
test -f "$work/repository/example/hello/1.0.0/hello-1.0.0.pom"

echo "== the aliases of the user deps.edn run offline once locked"
mkdir -p "$CLJ_CONFIG"
# The Clojure CLI copied its read-only example deps.edn here on first use.
rm -f "$CLJ_CONFIG/deps.edn"
echo '{:aliases {:nrepl {:extra-deps {nrepl/nrepl {:mvn/version "1.3.0"}}}}}' >"$CLJ_CONFIG/deps.edn"
"$cli" lock --user-aliases --mirror "$mirror"
# The relock kept the commands of the lockfile.
test "$("$jq" '.test | length' clojure-cli-purifier.lock.json)" = 3
# The prefetch of the old lockfile is refused until prefetch runs again.
if PATH="$PWD/.clojure-cli-purifier/bin:$PATH" clojure -M:test 2>"$work/old-prefetch.log"; then
  echo "clojure ran on the prefetch of the old lockfile" >&2
  exit 1
fi
grep -q 'run clojure-cli-purifier prefetch' "$work/old-prefetch.log"
"$cli" prefetch
(
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
  export PATH="$PWD/.clojure-cli-purifier/bin:$PATH"
  clojure -M:nrepl -m nrepl.cmdline --help | grep -q -- '--interactive'
)

echo "== git dependencies that need preparing, and two commits of one library"
# A library with two commits. The first is tagged, and the second is its
# child. Its deps.edn declares :deps/prep-lib, which generates a namespace.
# Fixed authors and dates give the commits fixed hashes.
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z'
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
gitrepo="$work/repos/lib"
mkdir -p "$gitrepo/src/lib" "$gitrepo/build"
git -C "$gitrepo" init -q -b main
cat >"$gitrepo/deps.edn" <<'EOF'
{:paths ["src" "generated"]
 :deps/prep-lib {:alias :prep :fn gen :ensure "generated"}
 :aliases {:prep {:paths ["build"] :ns-default prep}}}
EOF
cat >"$gitrepo/build/prep.clj" <<'EOF'
(ns prep)
(defn gen [_]
  (let [file (java.io.File. "generated/gen/value.clj")]
    (.mkdirs (.getParentFile file))
    (spit file "(ns gen.value) (def v 42)")))
EOF
echo '(ns lib.core) (defn which [] "one")' >"$gitrepo/src/lib/core.clj"
git -C "$gitrepo" add -A
git -C "$gitrepo" commit -q -m one
git -C "$gitrepo" tag v1
echo '(ns lib.core) (defn which [] "two")' >"$gitrepo/src/lib/core.clj"
git -C "$gitrepo" commit -q -am two
git -C "$gitrepo" tag v2
one=$(git -C "$gitrepo" rev-parse HEAD~1)
two=$(git -C "$gitrepo" rev-parse HEAD)
url="file://$gitrepo"

# An application that takes the second commit by tag and short commit, and the
# first by tag through a local dependency. The Clojure CLI keeps the
# second, which descends from the first.
app="$work/gitapp"
mkdir -p "$app/src/app" "$app/mid"
cat >"$app/deps.edn" <<EOF
{:paths ["src"]
 :deps {org.clojure/clojure {:mvn/version "1.12.3"}
        test/lib {:git/url "$url" :git/tag "v2" :git/sha "${two:0:7}"}
        test/mid {:local/root "mid"}}
 :aliases {:run {:main-opts ["-m" "app.main"]}}}
EOF
cat >"$app/mid/deps.edn" <<EOF
{:deps {test/lib {:git/url "$url" :git/tag "v1" :git/sha "${one:0:7}"}}}
EOF
cat >"$app/src/app/main.clj" <<'EOF'
(ns app.main (:require [gen.value :as g] [lib.core :as l]))
(defn -main [& _] (println "value" g/v (l/which)))
EOF
(cd "$app" && "$cli" lock --test "-M:run" --mirror "$mirror")
lock="$app/clojure-cli-purifier.lock.json"
test "$("$jq" '[.git[] | select(.git.url == "'"$url"'")] | length' "$lock")" = 2
test "$("$jq" '.gitRepos[0].commits | length' "$lock")" = 2
test "$("$jq" -r '.gitRepos[0].tags.v1' "$lock")" = "$one"

# The Nix build takes the checkouts through the fetchgit replacement, which
# reads the local repository, and prepares the library in the sandbox.
built=$(nix build --no-link --print-out-paths --impure --expr "
  let
    flake = builtins.getFlake \"git+file://$root\";
    pkgs = import flake.inputs.nixpkgs {
      system = builtins.currentSystem;
      overlays = [ flake.overlays.default ];
    };
  in
  (pkgs.clojure-cli-purifier.buildClojureCliProject {
    src = /. + \"$app\";
    fetchers.fetchgit = args: builtins.fetchGit {
      inherit (args) url rev;
      narHash = args.hash;
      allRefs = true;
    };
  }).tests")
test -d "$built"
nix log "$built" | grep -qx 'value 42 two'


echo "== a lockfile kept outside the project, by flag and by environment"
external="$work/packaging/clojure-cli-purifier.lock.json"
cp -r "$root/tests/fixtures/mono" "$work/external"
rm "$work/external/app/clojure-cli-purifier.lock.json"
(
  cd "$work/external/app"
  "$cli" lock --lockfile "$external" --source .. --test "-M:run" --mirror "$mirror"
  test ! -e clojure-cli-purifier.lock.json
  CLOJURE_CLI_PURIFIER_LOCKFILE="$external" "$cli" prefetch
  test -L "$work/packaging/.clojure-cli-purifier/env"
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
  "$work/packaging/.clojure-cli-purifier/bin/clojure" -M:run | grep -qx '{"from":"lib"}'
)
cmp "$external" "$root/tests/fixtures/mono/app/clojure-cli-purifier.lock.json"

echo "== a lock through a mirror records the repository URL and the mirror"
cp -r "$root/tests/fixtures/mono" "$work/mono"
(cd "$work/mono/app" && "$cli" lock --force --mirror "$mirror")
mirrored="$work/mono/app/clojure-cli-purifier.lock.json"
test "$("$jq" '[.artifacts[] | select(.url | startswith("https://repo1.maven.org/maven2/"))] | length' "$mirrored")" -gt 0
test "$("$jq" '[.artifacts[] | select((.url | startswith("https://repo1.maven.org/maven2/")) and (.mirrors | length) != 1)] | length' "$mirrored")" = 0
test "$("$jq" '[.artifacts[] | select(.url | startswith("https://maven-central.storage-download"))] | length' "$mirrored")" = 0

echo "== all interactive checks passed"
