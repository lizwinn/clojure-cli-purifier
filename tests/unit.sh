#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Unit tests of the functions the lock run uses to read and write files:
# the functions of lib.sh, and the helper the command runs on the tools
# jar of the Clojure CLI. The `unit` check runs it in the sandbox, with
# LIB_SH, HELPER, TOOLS_JAR and JAVA set.
set -euo pipefail
# shellcheck source=../pkgs/clojure-cli-purifier/lib.sh
source "$LIB_SH"

work=$(mktemp -d)
failures=0

expect() {
  local name=$1 want=$2 got=$3
  if [ "$want" != "$got" ]; then
    printf 'FAIL %s\n  want: %q\n  got:  %q\n' "$name" "$want" "$got"
    failures=$((failures + 1))
  else
    echo "ok   $name"
  fi
}

helper() {
  "$JAVA" -cp "$TOOLS_JAR" clojure.main "$HELPER" "$@"
}

# Paths of the project directory and its source root.
expect "inProject at the root" "deps.edn" "$(inProject . deps.edn)"
expect "inProject in a directory" "app/deps.edn" "$(inProject app deps.edn)"
expect "sourceRootOf at the root" "/src/app" "$(sourceRootOf /src/app .)"
expect "sourceRootOf in a directory" "/src" "$(sourceRootOf /src/app app)"
expect "sourceRootOf in a nested directory" "/src" "$(sourceRootOf /src/apps/web apps/web)"

# The definition files: the project's deps.edn and build.clj first, then
# every other deps.edn, sorted, without build outputs.
tree="$work/tree"
mkdir -p "$tree/app" "$tree/lib/a" "$tree/lib/b" "$tree/app/target" "$tree/.git"
touch "$tree/app/deps.edn" "$tree/app/build.clj" "$tree/lib/b/deps.edn" "$tree/lib/a/deps.edn" \
  "$tree/app/target/deps.edn" "$tree/.git/deps.edn"
expect "definitionFiles of a project directory" \
  "$(printf '%s\n' app/deps.edn app/build.clj lib/a/deps.edn lib/b/deps.edn)" \
  "$(definitionFiles "$tree" app)"
mkdir -p "$work/single"
touch "$work/single/deps.edn"
expect "definitionFiles of a project without build.clj" "deps.edn" "$(definitionFiles "$work/single" .)"

# The definition hash is the SHA-256 of the files one after the other, and
# a missing file adds nothing.
printf 'one' >"$work/single/deps.edn"
printf 'two' >"$work/single/build.clj"
expect "definitionHash" "$(printf 'onetwo' | sha256sum | cut -d' ' -f1)" \
  "$(definitionHash "$work/single" deps.edn build.clj missing.edn)"

# settings.xml for the lock run: the proxy of https_proxy, with and without
# credentials and port, or the settings.xml of the user.
settingsWith() {
  local proxy=$1 dir
  dir=$(mktemp -d)
  (https_proxy=$proxy HTTPS_PROXY="" writeSettings "$dir/m2" "$dir/home")
  cat "$dir/m2/settings.xml"
}
settings=$(settingsWith http://user:secret@proxy.example:3128)
expect "proxy host" "1" "$(grep -c '<host>proxy.example</host><port>3128</port>' <<<"$settings")"
expect "proxy credentials" "1" "$(grep -c '<username>user</username><password>secret</password>' <<<"$settings")"
settings=$(settingsWith http://proxy.example)
expect "proxy without port" "1" "$(grep -c '<host>proxy.example</host><port>80</port>' <<<"$settings")"
expect "proxy without credentials" "0" "$(grep -c '<username>' <<<"$settings" || true)"
mkdir -p "$work/home/.m2"
echo '<settings><!-- the user --></settings>' >"$work/home/.m2/settings.xml"
writeSettings "$work/copied" "$work/home"
expect "the settings.xml of the user" "<settings><!-- the user --></settings>" "$(cat "$work/copied/settings.xml")"

# Mirrors: added to a settings.xml with or without a <mirrors> element, or
# to a new one, and read back with the repository each serves.
printf '<settings>\n</settings>\n' >"$work/plain.xml"
addMirrors "$work/plain.xml" central=https://mirror.example/maven2/
expect "a mirror in a settings.xml without mirrors" \
  "$(printf 'purifier-central\thttps://mirror.example/maven2/\tcentral')" "$(mirrors "$work/plain.xml")"
printf '<settings>\n<mirrors>\n<mirror>\n<id>corp</id>\n<mirrorOf>*</mirrorOf>\n<url>https://corp.example/</url>\n</mirror>\n</mirrors>\n</settings>\n' >"$work/mirrored.xml"
addMirrors "$work/mirrored.xml" clojars=https://clojars-mirror.example/
expect "a mirror in a settings.xml with mirrors" \
  "$(printf 'purifier-clojars\thttps://clojars-mirror.example/\tclojars\ncorp\thttps://corp.example/\t*')" \
  "$(mirrors "$work/mirrored.xml")"
addMirrors "$work/new.xml" central=https://a.example/ clojars=https://b.example/
expect "mirrors in a new settings.xml" "2" "$(mirrors "$work/new.xml" | wc -l)"
expect "no mirrors" "" "$(mirrors "$work/none.xml")"

# The repository Maven Resolver recorded for a file.
mkdir -p "$work/repo/a/1.0"
printf '#NOTE: internal\n#Sat Nov 01 2026\na-1.0.jar>central=\na-1.0.pom>clojars=\n' >"$work/repo/a/1.0/_remote.repositories"
expect "remoteId of a jar" "central" "$(remoteId "$work/repo/a/1.0" a-1.0.jar)"
expect "remoteId of a POM" "clojars" "$(remoteId "$work/repo/a/1.0" a-1.0.pom)"
expect "remoteId of an untracked file" "" "$(remoteId "$work/repo/a/1.0" a-1.0-sources.jar)"
expect "remoteId without a record" "" "$(remoteId "$work/repo/missing" a.jar)"

# Command lines split into words.
expect "commandsJson" '[["-T:build","uber"],["-M:test","--focus","x"]]' "$(commandsJson "-T:build uber" "-M:test  --focus x")"
expect "commandsJson without commands" '[]' "$(commandsJson)"

# The helper: aliases, repositories of basis files, and SNAPSHOT names.
cat >"$work/deps.edn" <<'EOF'
{:deps {} :aliases {:test {} :build {:ns-default build} #_ :ignored :dev {}}}
EOF
expect "helper aliases" "$(printf ':build\n:dev\n:test')" "$(helper aliases "$work/deps.edn")"
cat >"$work/a.basis" <<'EOF'
{:mvn/repos {"central" {:url "https://repo1.maven.org/maven2/"}
             "clojars" {:url "https://repo.clojars.org/"}}
 :libs {org.clojure/clojure {:mvn/version "1.12.3" :paths ["/x.jar"]}}
 :argmap #object[java.io.File 0x1 "/tmp"]}
EOF
expect "helper repos" "$(printf 'central\thttps://repo1.maven.org/maven2/\nclojars\thttps://repo.clojars.org/')" \
  "$(helper repos "$work/a.basis" | sort)"
cat >"$work/old.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<metadata>
  <groupId>hiccup</groupId>
  <artifactId>hiccup</artifactId>
  <version>1.0.0-SNAPSHOT</version>
  <versioning>
    <snapshot><timestamp>20120218.070543</timestamp><buildNumber>1</buildNumber></snapshot>
  </versioning>
</metadata>
EOF
expect "snapshot-name in the older format" "hiccup-1.0.0-20120218.070543-1.jar" \
  "$(helper snapshot-name "$work/old.xml" hiccup-1.0.0-SNAPSHOT.jar)"
cat >"$work/new.xml" <<'EOF'
<metadata>
  <groupId>g</groupId>
  <artifactId>lib</artifactId>
  <version>2.0-SNAPSHOT</version>
  <versioning>
    <snapshotVersions>
      <snapshotVersion><extension>jar</extension><value>2.0-20250101.010101-3</value></snapshotVersion>
      <snapshotVersion><classifier>sources</classifier><extension>jar</extension><value>2.0-20250101.010102-4</value></snapshotVersion>
      <snapshotVersion><extension>pom</extension><value>2.0-20250101.010101-3</value></snapshotVersion>
    </snapshotVersions>
  </versioning>
</metadata>
EOF
expect "snapshot-name of a jar" "lib-2.0-20250101.010101-3.jar" "$(helper snapshot-name "$work/new.xml" lib-2.0-SNAPSHOT.jar)"
expect "snapshot-name of a classified jar" "lib-2.0-20250101.010102-4-sources.jar" \
  "$(helper snapshot-name "$work/new.xml" lib-2.0-SNAPSHOT-sources.jar)"
expect "snapshot-name of a POM" "lib-2.0-20250101.010101-3.pom" "$(helper snapshot-name "$work/new.xml" lib-2.0-SNAPSHOT.pom)"

if [ $failures -gt 0 ]; then
  echo "$failures unit tests failed"
  exit 1
fi
echo "all unit tests passed"
