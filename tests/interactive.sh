#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Checks the commands that run outside the Nix sandbox, on a copy of the
# hello fixture:
#
#   - `clojure-cli-purifier lock` leaves an up-to-date lockfile as it is;
#   - `clojure-cli-purifier clojure` runs the tests, the SNAPSHOT and the
#     version range aliases, and the uberjar build with no network access,
#     from the locked downloads alone;
#   - `clojure-cli-purifier publish` deploys the jar and POM that Nix built
#     to a file repository.
#
# The publish step downloads its deploy tool, so it needs the network. The
# offline steps unset the proxy variables, which in a sandbox without
# direct network access cuts the JVMs off. It runs from any directory.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cli=$(nix build --no-link --print-out-paths "$root#cli")/bin/clojure-cli-purifier
java=$(nix build --no-link --print-out-paths "$root#cli.jdk")/bin/java
jq=$(nix build --no-link --print-out-paths --inputs-from "$root" 'nixpkgs#jq^bin')/bin/jq
work=$(mktemp -d "${TMPDIR:-/tmp}/clojure-cli-purifier-interactive.XXXXXX")
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
cp -r "$root/tests/fixtures/hello" "$work/hello"
cd "$work/hello"
# The Clojure CLI creates its user configuration on first use, so the test
# gives it one of its own.
export CLJ_CONFIG="$work/config"

echo "== lock leaves an up-to-date lockfile alone"
"$cli" lock | grep -q 'is up to date'

echo "== offline runs from the locked downloads"
(
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
  export JAVA_TOOL_OPTIONS="-Djava.io.tmpdir=$work"
  "$cli" clojure -M:test | grep -q '0 failures, 0 errors'
  "$cli" clojure -M:snapshot | grep -qx '<b>snapshot</b>'
  "$cli" clojure -M:range | grep -qx 'range 49'
  "$cli" clojure -T:build uber
  "$java" -jar target/hello-1.0.0-standalone.jar | grep -qx '<p>purified</p>'
)

echo "== publish deploys what Nix built"
built=$("$cli" publish --dry-run | sed -n 's/^jar: //p')
test -f "$built"
mkdir -p "$work/repository" "$work/home/.m2"
# The deploy tool resolves into a home of its own. Maven Resolver reads no
# proxy from the environment, so a proxy of https_proxy goes into its
# settings.xml.
proxy=${https_proxy:-}
if [ -n "$proxy" ]; then
  rest=${proxy#*://}
  auth=
  if [[ $rest == *@* ]]; then
    auth=${rest%%@*}
    rest=${rest#*@}
  fi
  hostport=${rest%%/*}
  {
    echo "<settings><proxies><proxy><id>environment</id><active>true</active><protocol>http</protocol>"
    echo "<host>${hostport%%:*}</host><port>${hostport##*:}</port>"
    if [ -n "$auth" ]; then echo "<username>${auth%%:*}</username><password>${auth#*:}</password>"; fi
    echo "</proxy></proxies></settings>"
  } >"$work/home/.m2/settings.xml"
fi
JAVA_TOOL_OPTIONS="-Djava.io.tmpdir=$work" \
  CLJ_JVM_OPTS="-Duser.home=$work/home" JAVA_OPTS="-Duser.home=$work/home" \
  "$cli" publish --repository "local=file://$work/repository"
cmp "$built" "$work/repository/example/hello/1.0.0/hello-1.0.0.jar"
test -f "$work/repository/example/hello/1.0.0/hello-1.0.0.pom"

echo "== the aliases of the user deps.edn run offline once locked"
mkdir -p "$CLJ_CONFIG"
# The Clojure CLI copied its read-only example deps.edn here on first use.
rm -f "$CLJ_CONFIG/deps.edn"
echo '{:aliases {:nrepl {:extra-deps {nrepl/nrepl {:mvn/version "1.3.0"}}}}}' >"$CLJ_CONFIG/deps.edn"
"$cli" lock --user-aliases
# The relock kept the commands of the lockfile.
test "$("$jq" '.test | length' clojure-cli-purifier.lock.json)" = 3
(
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
  export JAVA_TOOL_OPTIONS="-Djava.io.tmpdir=$work"
  "$cli" clojure -M:nrepl -m nrepl.cmdline --help | grep -q -- '--interactive'
)

echo "== all interactive checks passed"
