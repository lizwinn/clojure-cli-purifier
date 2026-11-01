# SPDX-License-Identifier: MIT
#
# The functions of the clojure-cli-purifier command that read and write
# files without running the Clojure CLI. The package puts them before the
# command, and the unit tests (tests/unit.sh) source them on their own.

# A path of the project directory, relative to the source root.
inProject() {
  local projectDir=$1 file=$2
  if [ "$projectDir" = . ]; then echo "$file"; else echo "$projectDir/$file"; fi
}

# The files that decide what the project resolves, relative to the source
# root: the deps.edn and build.clj of the project, and the deps.edn of
# every other directory of the source root, which a local dependency may
# be.
definitionFiles() {
  local sourceRoot=$1 projectDir=$2 depsEdn
  depsEdn=$(inProject "$projectDir" deps.edn)
  echo "$depsEdn"
  if [ -f "$sourceRoot/$(inProject "$projectDir" build.clj)" ]; then inProject "$projectDir" build.clj; fi
  (
    cd "$sourceRoot" || exit
    find . \( -name target -o -name .cpcache -o -name .git -o -name node_modules \) -prune \
      -o -name deps.edn -type f -printf '%P\n' | grep -vxF "$depsEdn" | LC_ALL=C sort || true
  )
}

# The SHA-256 of the given files of the source root, in that order, in
# hex. The Nix builder hashes the same files in the same order.
definitionHash() {
  local sourceRoot=$1 file
  shift
  for file in "$@"; do
    if [ -f "$sourceRoot/$file" ]; then cat "$sourceRoot/$file"; fi
  done | sha256sum | cut -d' ' -f1
}

# The directory of the project relative to its source root, as the
# lockfile records it.
lockProjectDir() {
  jq -r '.projectDir // "."' "$1"
}

# The source root of a project root, by the project directory the lockfile
# records.
sourceRootOf() {
  local root=$1 projectDir=$2
  if [ "$projectDir" = . ]; then echo "$root"; else echo "${root%/"$projectDir"}"; fi
}

# Writes settings.xml for the lock run. A settings.xml of the user brings
# its proxies, mirrors and repository credentials. Without one, the proxy
# of https_proxy applies, because Maven Resolver reads no proxy from the
# environment.
writeSettings() {
  local m2=$1 realHome=$2 proxy rest auth hostport host port user pass
  mkdir -p "$m2"
  if [ -f "$realHome/.m2/settings.xml" ]; then
    cp "$realHome/.m2/settings.xml" "$m2/settings.xml"
    return
  fi
  proxy=${https_proxy:-${HTTPS_PROXY:-}}
  [ -n "$proxy" ] || return 0
  rest=${proxy#*://}
  auth=
  if [[ $rest == *@* ]]; then
    auth=${rest%%@*}
    rest=${rest#*@}
  fi
  hostport=${rest%%/*}
  host=${hostport%%:*}
  port=${hostport##*:}
  if [ "$port" = "$hostport" ]; then port=80; fi
  user=${auth%%:*}
  pass=${auth#*:}
  {
    echo '<settings>'
    echo '<proxies><proxy><id>environment</id><active>true</active>'
    echo "<protocol>http</protocol><host>$host</host><port>$port</port>"
    if [ -n "$auth" ]; then echo "<username>$user</username><password>$pass</password>"; fi
    echo '<nonProxyHosts>localhost|127.0.0.1</nonProxyHosts></proxy></proxies>'
    echo '</settings>'
  } >"$m2/settings.xml"
}

# Adds a mirror to a settings.xml for each "<id>=<url>" given: the mirror
# serves the repository of that id, from that URL. A file that does not
# exist yet becomes a settings.xml with only the mirrors.
addMirrors() {
  local settings=$1 spec block=""
  shift
  [ $# -gt 0 ] || return 0
  for spec in "$@"; do
    block="$block<mirror>
<id>purifier-${spec%%=*}</id>
<mirrorOf>${spec%%=*}</mirrorOf>
<url>${spec#*=}</url>
</mirror>
"
  done
  if [ ! -f "$settings" ]; then
    printf '<settings>\n</settings>\n' >"$settings"
  fi
  if grep -q '<mirrors>' "$settings"; then
    awk -v block="$block" '!done && sub(/<mirrors>/, "<mirrors>\n" block) { done = 1 } { print }' \
      "$settings" >"$settings.tmp"
  else
    awk -v block="$block" '!done && sub(/<\/settings>/, "<mirrors>\n" block "</mirrors>\n</settings>") { done = 1 } { print }' \
      "$settings" >"$settings.tmp"
  fi
  mv "$settings.tmp" "$settings"
}

# Prints "<id>\t<url>\t<mirrorOf>" for each mirror of a settings.xml.
mirrors() {
  [ -f "$1" ] || return 0
  awk '
    /<mirror>/ { inside = 1; id = ""; url = ""; of = "" }
    inside && /<id>/ { id = $0; gsub(/.*<id>|<\/id>.*/, "", id) }
    inside && /<url>/ { url = $0; gsub(/.*<url>|<\/url>.*/, "", url) }
    inside && /<mirrorOf>/ { of = $0; gsub(/.*<mirrorOf>|<\/mirrorOf>.*/, "", of) }
    /<\/mirror>/ { print id "\t" url "\t" of; inside = 0 }
  ' "$1"
}

# Prints the id of the repository a file of a local repository directory
# came from, as its _remote.repositories file records it, or nothing.
remoteId() {
  awk -F'>' -v file="$2" '$1 == file { sub(/=$/, "", $2); print $2; exit }' \
    "$1/_remote.repositories" 2>/dev/null || true
}

# Prints a JSON list of command lines, each a list of words, from command
# lines given as strings. Each splits into words the way the shell splits
# an unquoted word.
commandsJson() {
  local line
  local -a words
  for line in "$@"; do
    read -ra words <<<"$line"
    printf '%s\n' "${words[@]}" | jq -R . | jq -sc .
  done | jq -sc .
}
