# SPDX-License-Identifier: MIT
#
# clojure-cli-purifier: locks the downloads of a deps.edn project, runs the
# Clojure CLI on the locked downloads, and publishes what Nix built.
#
# The package sets PURIFIER_LIB (the Nix library, nix/lib), PURIFIER_FORMAT
# (the lock format version it reads), PURIFIER_HELPER (helper.clj),
# PURIFIER_TOOLS_JAR (the tools jar of the Clojure CLI, which runs the
# helper), PURIFIER_NIXPKGS (the nixpkgs source the package was built from)
# and JAVA_CMD (the JVM of the Clojure CLI).

lockName=clojure-cli-purifier.lock.json

usage() {
  cat <<'EOF'
Usage:
  clojure-cli-purifier lock [--force] [--build ARGS]... [--test ARGS]...
                            [--alias :NAME]... [--user-aliases]
                            [--source DIR]
      Runs the project with an empty local Maven repository and an empty
      gitlibs directory, and records every file the Clojure CLI downloads,
      the outputs of the build commands and the commands themselves in
      clojure-cli-purifier.lock.json.

      --build ARGS   A Clojure CLI command line the Nix build runs, such as
                     "-T:build uber". It may repeat. The default is the
                     uber or jar function of build.clj, when there is one.
      --test ARGS    A Clojure CLI command line the Nix build runs when its
                     checks are on, such as "-M:test". It may repeat.
      --alias :NAME  An alias to prepare. The default is every alias of
                     deps.edn. It may repeat.
      --user-aliases Also prepares the aliases of the user deps.edn, for
                     the interactive mode. The Nix build ignores them.
                     --no-user-aliases stops preparing them.
      --source DIR   The directory that holds the project and the local
                     dependencies outside it, such as the root of a
                     repository with several projects. The Nix build takes
                     it as src. The default is the project root.

      Each option replaces its part of an existing lockfile, and a relock
      keeps every part no option names. Without options or --force, an
      up-to-date lockfile is left as it is.
  clojure-cli-purifier clojure ARGS...
      Runs the Clojure CLI offline, with a local Maven repository and a
      gitlibs directory that hold exactly the locked downloads.
  clojure-cli-purifier publish [--repository ID=URL] [--dry-run]
      Builds the project with Nix and deploys the jar and POM the build
      made, without compiling anything outside the sandbox. The default
      repository is Clojars, with CLOJARS_USERNAME and CLOJARS_PASSWORD.
      Another repository takes its credentials from the server of the same
      id in ~/.m2/settings.xml.
EOF
}

die() {
  echo "clojure-cli-purifier: $*" >&2
  exit 1
}

# The project root: the nearest directory, from here upwards, that holds
# deps.edn.
projectRoot() {
  local dir
  dir=$(pwd)
  while [ "$dir" != / ]; do
    if [ -f "$dir/deps.edn" ]; then
      echo "$dir"
      return
    fi
    dir=$(dirname "$dir")
  done
  die "no deps.edn in $(pwd) or above it"
}

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

clojureVersion() {
  clojure --version | sed -n 's/^Clojure CLI version //p'
}

javaVersion() {
  "$JAVA_CMD" -XshowSettings:properties -version 2>&1 | sed -n 's/^ *java.version = //p'
}

helper() {
  "$JAVA_CMD" -cp "$PURIFIER_TOOLS_JAR" clojure.main "$PURIFIER_HELPER" "$@"
}

# Whether the lockfile was made from this project definition, by this lock
# format and with this Clojure CLI.
lockIsCurrent() {
  local root=$1 lockFile=$2 files sourceRoot
  [ -f "$lockFile" ] || return 1
  [ "$(jq -r .version "$lockFile")" = "$PURIFIER_FORMAT" ] || return 1
  sourceRoot=$(sourceRootOf "$root" "$(lockProjectDir "$lockFile")")
  mapfile -t files < <(jq -r '.definitionFiles[]' "$lockFile")
  [ "$(jq -r .definitionHash "$lockFile")" = "$(definitionHash "$sourceRoot" "${files[@]}")" ] &&
    [ "$(jq -r .clojureVersion "$lockFile")" = "$(clojureVersion)" ]
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
    echo '<settings><proxies><proxy><id>environment</id><active>true</active>'
    echo "<protocol>http</protocol><host>$host</host><port>$port</port>"
    if [ -n "$auth" ]; then echo "<username>$user</username><password>$pass</password>"; fi
    echo '<nonProxyHosts>localhost|127.0.0.1</nonProxyHosts></proxy></proxies></settings>'
  } >"$m2/settings.xml"
}

# Prints "<id>\t<url>" for each mirror of a settings.xml.
mirrors() {
  [ -f "$1" ] || return 0
  awk '
    /<mirror>/ { inside = 1; id = ""; url = "" }
    inside && /<id>/ { id = $0; gsub(/.*<id>|<\/id>.*/, "", id) }
    inside && /<url>/ { url = $0; gsub(/.*<url>|<\/url>.*/, "", url) }
    /<\/mirror>/ { print id "\t" url; inside = 0 }
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

cmdLock() {
  local force=0 userAliases="" source=""
  local -a builds=() tests=() aliases=()
  while [ $# -gt 0 ]; do
    case $1 in
    --force) force=1 ;;
    --build)
      [ $# -ge 2 ] || die "lock: --build takes a command line"
      builds+=("$2")
      shift
      ;;
    --test)
      [ $# -ge 2 ] || die "lock: --test takes a command line"
      tests+=("$2")
      shift
      ;;
    --alias)
      [ $# -ge 2 ] || die "lock: --alias takes an alias"
      aliases+=("$2")
      shift
      ;;
    --user-aliases) userAliases=true ;;
    --no-user-aliases) userAliases=false ;;
    --source)
      [ $# -ge 2 ] || die "lock: --source takes a directory"
      source=$2
      shift
      ;;
    *) die "lock: unknown argument $1" ;;
    esac
    shift
  done

  local root lockFile
  root=$(projectRoot)
  lockFile="$root/$lockName"
  local explicit=0
  if [ ${#builds[@]} -gt 0 ] || [ ${#tests[@]} -gt 0 ] || [ ${#aliases[@]} -gt 0 ] || [ -n "$userAliases" ] || [ -n "$source" ]; then
    explicit=1
  fi

  # The source root holds the project and its local dependencies. A relock
  # without --source keeps the source root of the existing lockfile.
  local sourceRoot projectDir
  if [ -n "$source" ]; then
    sourceRoot=$(cd "$source" && pwd)
  elif [ -f "$lockFile" ]; then
    sourceRoot=$(sourceRootOf "$root" "$(lockProjectDir "$lockFile")")
  else
    sourceRoot=$root
  fi
  case $root in
  "$sourceRoot") projectDir=. ;;
  "$sourceRoot"/*) projectDir=${root#"$sourceRoot/"} ;;
  *) die "lock: the project $root is not inside the source root $sourceRoot" ;;
  esac
  if [ $force = 0 ] && [ $explicit = 0 ] && lockIsCurrent "$root" "$lockFile"; then
    echo "clojure-cli-purifier: $lockFile is up to date"
    return
  fi

  # Each option replaces its part of the existing lockfile, and a part no
  # option names keeps its value from the lockfile.
  local buildJson testJson aliasJson
  local hasLock=0
  if [ -f "$lockFile" ]; then hasLock=1; fi
  if [ ${#builds[@]} -gt 0 ]; then
    buildJson=$(commandsJson "${builds[@]}")
  elif [ $hasLock = 1 ]; then
    buildJson=$(jq -c .build "$lockFile")
  else
    if [ -f "$root/build.clj" ]; then
      if grep -q '(defn uber\b' "$root/build.clj"; then
        builds=("-T:build uber")
      elif grep -q '(defn jar\b' "$root/build.clj"; then
        builds=("-T:build jar")
      fi
    fi
    buildJson=$(commandsJson "${builds[@]}")
  fi
  if [ ${#tests[@]} -gt 0 ]; then
    testJson=$(commandsJson "${tests[@]}")
  elif [ $hasLock = 1 ]; then
    testJson=$(jq -c .test "$lockFile")
  else
    testJson='[]'
  fi
  if [ ${#aliases[@]} -gt 0 ]; then
    aliasJson=$(printf '%s\n' "${aliases[@]}" | jq -R . | jq -sc .)
  elif [ $hasLock = 1 ]; then
    aliasJson=$(jq -c .aliases "$lockFile")
  else
    aliasJson=null
  fi
  if [ -z "$userAliases" ]; then
    if [ $hasLock = 1 ]; then userAliases=$(jq -r .userAliases "$lockFile"); else userAliases=false; fi
  fi

  local work
  work=$(mktemp -d "${TMPDIR:-/tmp}/clojure-cli-purifier.XXXXXX")
  # shellcheck disable=SC2064 # work is fixed from here on
  trap "chmod -R u+w '$work' 2>/dev/null; rm -rf '$work'" EXIT
  mkdir -p "$work/source" "$work/home" "$work/config" "$work/cache" "$work/gitlibs" "$work/java-tmp"
  tar -C "$sourceRoot" --exclude=target --exclude=.cpcache --exclude=.git -cf - . | tar -C "$work/source" -xf -
  local project="$work/source"
  if [ "$projectDir" != . ]; then project="$work/source/$projectDir"; fi

  # The lock run sees what a sandboxed build sees: an empty local
  # repository, an empty gitlibs directory and no user configuration. The
  # JVMs take their local repository from user.home, which HOME does not
  # set.
  local realHome=$HOME userConfig
  userConfig="${CLJ_CONFIG:-${XDG_CONFIG_HOME:-$realHome/.config}/clojure}"
  if [ -z "${CLJ_CONFIG:-}" ] && [ ! -d "$userConfig" ]; then userConfig="$realHome/.clojure"; fi
  writeSettings "$work/home/.m2" "$realHome"
  echo '{}' >"$work/config/deps.edn"
  export HOME="$work/home"
  export CLJ_CONFIG="$work/config"
  export CLJ_CACHE="$work/cache"
  export GITLIBS="$work/gitlibs"
  export CLJ_JVM_OPTS="-Duser.home=$HOME -Djava.io.tmpdir=$work/java-tmp"
  export JAVA_OPTS="$CLJ_JVM_OPTS"
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
  local m2="$work/home/.m2/repository"

  # The aliases to prepare: the given ones, or every alias of the project.
  local -a prepare
  if [ "$aliasJson" = null ]; then
    mapfile -t prepare < <(helper aliases "$project/deps.edn")
  else
    mapfile -t prepare < <(jq -r '.[]' <<<"$aliasJson")
  fi
  local -a userPrepare=()
  if [ "$userAliases" = true ] && [ -f "$userConfig/deps.edn" ]; then
    mapfile -t userPrepare < <(helper aliases "$userConfig/deps.edn")
  fi

  echo "clojure-cli-purifier: locking $root"
  local alias log="$work/log"
  : >"$log"
  (
    cd "$project" || exit
    clojure -P
    for alias in "${prepare[@]}"; do
      clojure -P "-M$alias"
    done
  ) 2>&1 | tee -a "$log" || die "preparing the project failed; see the output above"
  # A POM can choose dependencies by architecture, through a profile that
  # Maven Resolver activates from os.arch. The project resolves again for
  # each architecture the flake builds for, so the lock holds what every
  # one of them resolves.
  local thisArch otherArch
  thisArch=$("$JAVA_CMD" -XshowSettings:properties -version 2>&1 | sed -n 's/^ *os.arch = //p')
  for otherArch in amd64 aarch64; do
    [ "$otherArch" != "$thisArch" ] || continue
    local archOpts="$CLJ_JVM_OPTS -Dos.arch=$otherArch"
    (
      cd "$project" || exit
      CLJ_JVM_OPTS=$archOpts clojure -Sforce -P
      for alias in "${prepare[@]}"; do
        CLJ_JVM_OPTS=$archOpts clojure -Sforce -P "-M$alias"
      done
    ) 2>&1 | tee -a "$log" || die "preparing the project for $otherArch failed; see the output above"
  done
  if [ ${#userPrepare[@]} -gt 0 ]; then
    # The aliases of the user deps.edn resolve with it, in a cache of their
    # own.
    (
      cd "$project" || exit
      export CLJ_CONFIG="$work/user-config"
      mkdir -p "$CLJ_CONFIG"
      cp "$userConfig/deps.edn" "$CLJ_CONFIG/deps.edn"
      for alias in "${userPrepare[@]}"; do
        CLJ_CACHE="$work/user-cache" clojure -Sforce -P "-M$alias"
      done
    ) 2>&1 | tee -a "$log" || die "preparing the user aliases failed; see the output above"
  fi

  # The git dependencies, before preparing them changes their checkouts.
  local gitEntries="$work/git.jsonl" gitRepos="$work/repos.jsonl"
  : >"$gitEntries"
  : >"$gitRepos"
  local bare url checkout rev rel copy hash tree index="$work/index"
  local -a revs commits parents
  while IFS= read -r bare; do
    url=$(git --git-dir="$bare" config remote.origin.url)
    revs=()
    for checkout in "$GITLIBS"/libs/*/*/*; do
      [ -f "$checkout/.git" ] || continue
      case $(sed -n 's/^gitdir: //p' "$checkout/.git") in
      "$bare"/*) ;;
      *) continue ;;
      esac
      rev=$(basename "$checkout")
      revs+=("$rev")
      rel=${checkout#"$GITLIBS/"}
      copy="$work/checkout"
      rm -rf "$copy"
      mkdir -p "$copy"
      tar -C "$checkout" --exclude=./.git -cf - . | tar -C "$copy" -xf -
      hash=$(nix-hash --type sha256 --sri "$copy")
      # The Nix build rebuilds the commit from the files of the checkout,
      # so the files must give the tree of the commit.
      tree=$(GIT_INDEX_FILE="$index" git --git-dir="$bare" --work-tree="$copy" -c core.autocrlf=false add --all --force . &&
        GIT_INDEX_FILE="$index" git --git-dir="$bare" write-tree)
      rm -f "$index"
      if [ "$tree" != "$(git --git-dir="$bare" rev-parse "$rev^{tree}")" ]; then
        die "the checkout of $url at $rev does not give the tree of its commit, so the Nix build could not rebuild the commit"
      fi
      jq -cn --arg path "$rel" --arg url "$url" --arg rev "$rev" --arg hash "$hash" \
        '{ path: $path, git: { url: $url, rev: $rev, submodules: false, leaveDotGit: false, commitObject: null }, hash: $hash }' >>"$gitEntries"
    done
    [ ${#revs[@]} -gt 0 ] || continue
    # The commits the Clojure CLI may read: the locked ones, and when one
    # repository has several, every commit between them and their merge
    # base, which an ancestry check walks. A commit with a parent outside
    # that set is a shallow boundary.
    if [ ${#revs[@]} = 1 ]; then
      commits=("${revs[0]}")
    else
      local base
      base=$(git --git-dir="$bare" merge-base --octopus "${revs[@]}")
      mapfile -t parents < <(git --git-dir="$bare" rev-parse "$base^@")
      mapfile -t commits < <(git --git-dir="$bare" rev-list "${revs[@]}" --not "${parents[@]}")
    fi
    local commitJson shallowJson tagJson c p
    commitJson=$(for c in "${commits[@]}"; do
      git --git-dir="$bare" cat-file commit "$c" | jq -Rs --arg sha "$c" '{ sha: $sha, object: . }'
    done | jq -sc .)
    shallowJson=$(for c in "${commits[@]}"; do
      read -ra parents < <(git --git-dir="$bare" rev-list --parents -n1 "$c" | cut -s -d' ' -f2-)
      if [ ${#parents[@]} = 0 ]; then
        continue
      fi
      for p in "${parents[@]}"; do
        if ! printf '%s\n' "${commits[@]}" | grep -qx "$p"; then
          echo "$c"
          break
        fi
      done
    done | LC_ALL=C sort -u | jq -R . | jq -sc .)
    tagJson=$(for c in "${revs[@]}"; do
      git --git-dir="$bare" tag --points-at "$c" | jq -R --arg rev "$c" '{ key: ., value: $rev }'
    done | jq -sc 'from_entries')
    jq -cn --arg path "${bare#"$GITLIBS/"}" --arg url "$url" \
      --argjson commits "$commitJson" --argjson shallow "$shallowJson" --argjson tags "$tagJson" \
      '{ path: $path, url: $url, commits: $commits, shallow: $shallow, tags: $tags }' >>"$gitRepos"
  done < <(find "$GITLIBS/_repos" -name HEAD -not -path '*/worktrees/*' -printf '%h\n' 2>/dev/null | LC_ALL=C sort)

  # Git dependencies that need preparing, then the build and its tests.
  local stamp="$work/stamp"
  touch "$stamp"
  sleep 1
  (
    cd "$project" || exit
    clojure -X:deps prep :aliases "[${prepare[*]}]"
    while IFS= read -r command; do
      mapfile -t words < <(jq -r '.[]' <<<"$command")
      echo "clojure-cli-purifier: clojure ${words[*]}"
      clojure "${words[@]}"
    done < <(jq -c '.[]' <<<"$buildJson" && jq -c '.[]' <<<"$testJson")
  ) 2>&1 | tee -a "$log" || die "the build failed; see the output above"

  # The outputs: the jars the build commands created.
  local outputs="$work/outputs.jsonl" output mainClass
  : >"$outputs"
  while IFS= read -r output; do
    mainClass=$(unzip -p "$project/$output" META-INF/MANIFEST.MF 2>/dev/null |
      tr -d '\r' | sed -n 's/^Main-Class: *//p' | jq -R . | jq -s 'first // null')
    jq -cn --arg path "$output" --argjson mainClass "$mainClass" '{ path: $path, mainClass: $mainClass }' >>"$outputs"
  done < <(cd "$project" && find . \( -name .cpcache -o -name classes \) -prune -o \
    \( -name '*.jar' -o -name '*.war' \) -type f -newer "$stamp" -printf '%P\n' | LC_ALL=C sort)

  # The project: from the POM the build wrote, or the directory name.
  local pom=null group="" name version=null pomPath pomFile
  name=$(basename "$root")
  pomPath=$(cd "$project" && find . -name .cpcache -prune -o -name pom.xml -type f -newer "$stamp" -printf '%P\n' | LC_ALL=C sort | head -1)
  if [ -n "$pomPath" ]; then
    pom=$(jq -n --arg p "$pomPath" '$p')
    pomFile="$project/$pomPath"
    pomField() {
      awk -v tag="$1" '
        /<parent>/ { p = 1 }
        /<\/parent>/ { p = 0; next }
        !p && index($0, "<" tag ">") { gsub(".*<" tag ">|</" tag ">.*", ""); print; exit }
      ' "$pomFile"
    }
    group=$(pomField groupId)
    name=$(pomField artifactId)
    version=$(pomField version | jq -R . | jq -s 'first // null')
  fi

  # The repositories the downloads came from, by the id Maven Resolver
  # records: those of every basis the Clojure CLI wrote, and the mirrors of
  # settings.xml.
  declare -A repositoryUrl
  local id
  while IFS=$'\t' read -r id url; do
    if [[ $url != */ ]]; then url="$url/"; fi
    repositoryUrl[$id]=$url
  done < <(
    mapfile -t bases < <(find "$project/.cpcache" "$work/cache" "$work/user-cache" -name '*.basis' 2>/dev/null)
    if [ ${#bases[@]} -gt 0 ]; then helper repos "${bases[@]}"; fi
    mirrors "$work/home/.m2/settings.xml"
  )

  # Every file in the local repository is a download, except the records
  # Maven Resolver keeps. Version lists change on the server, so they are
  # kept with their contents. The rest is named in the _remote.repositories
  # file of its directory, with the id of the repository it came from.
  local artifacts="$work/artifacts.jsonl" metadata="$work/metadata.jsonl"
  local -a untracked=() unknown=()
  : >"$artifacts"
  : >"$metadata"
  local dir name2 remote
  while IFS= read -r rel; do
    dir=$(dirname "$rel")
    name2=$(basename "$rel")
    case $name2 in
    _remote.repositories | *.lastUpdated | *.sha1 | *.md5 | *.sha256 | *.sha512)
      continue
      ;;
    maven-metadata*.xml)
      jq -cn --arg path "$rel" --rawfile contents "$m2/$rel" '{ path: $path, contents: $contents }' >>"$metadata"
      continue
      ;;
    resolver-status.properties)
      # The resolver checks a version list again a day after the time it
      # records, so the time becomes the year 2100. The comment lines hold
      # the date of the lock run, which a relock would change.
      jq -cn --arg path "$rel" --arg contents "$(sed -E '/^#/d; s/=[0-9]{13}$/=4102444800000/' "$m2/$rel")"$'\n' \
        '{ path: $path, contents: $contents }' >>"$metadata"
      continue
      ;;
    esac
    remote=$name2
    id=$(remoteId "$m2/$dir" "$name2")
    # Maven Resolver downloads a SNAPSHOT file under its timestamped name,
    # which it tracks, and keeps an untracked copy under the -SNAPSHOT
    # name. The copy comes from the same URL as the timestamped file the
    # metadata of its repository names.
    if [ -z "$id" ] && [[ $dir == *-SNAPSHOT && $name2 == *-SNAPSHOT* ]]; then
      local metadataFile candidate
      for metadataFile in "$m2/$dir"/maven-metadata-*.xml; do
        [ -f "$metadataFile" ] || continue
        candidate=$(helper snapshot-name "$metadataFile" "$name2")
        id=$(remoteId "$m2/$dir" "$candidate")
        if [ -n "$id" ]; then
          remote=$candidate
          break
        fi
      done
    fi
    if [ -z "$id" ]; then
      untracked+=("$rel")
      continue
    fi
    url=${repositoryUrl[$id]:-}
    if [ -z "$url" ]; then
      unknown+=("$rel (repository $id)")
      continue
    fi
    jq -cn --arg path "$rel" --arg url "$url$dir/$remote" --arg hash "$(nix-hash --type sha256 --flat --sri "$m2/$rel")" \
      '{ path: $path, url: $url, mirrors: [], hash: $hash }' >>"$artifacts"
  done < <(cd "$m2" && find . -type f -printf '%P\n' | LC_ALL=C sort)

  if [ ${#untracked[@]} -gt 0 ]; then
    printf '  %s\n' "${untracked[@]}" >&2
    die "Maven Resolver recorded no repository for the files above"
  fi
  if [ ${#unknown[@]} -gt 0 ]; then
    printf '  %s\n' "${unknown[@]}" >&2
    die "the files above came from repositories that neither the project nor settings.xml names"
  fi

  local -a files
  mapfile -t files < <(definitionFiles "$sourceRoot" "$projectDir")
  jq -n \
    --argjson version "$PURIFIER_FORMAT" \
    --arg clojureVersion "$(clojureVersion)" \
    --arg javaVersion "$(javaVersion)" \
    --arg projectDir "$projectDir" \
    --argjson definitionFiles "$(printf '%s\n' "${files[@]}" | jq -R . | jq -sc .)" \
    --arg definitionHash "$(definitionHash "$sourceRoot" "${files[@]}")" \
    --argjson aliases "$aliasJson" \
    --argjson prepared "$(printf '%s\n' "${prepare[@]}" | grep -v '^$' | jq -R . | jq -sc .)" \
    --argjson userAliases "$userAliases" \
    --argjson build "$buildJson" \
    --argjson test "$testJson" \
    --arg group "$group" --arg name "$name" --argjson projectVersion "$version" \
    --argjson pom "$pom" \
    --slurpfile outputs "$outputs" \
    --slurpfile artifacts "$artifacts" \
    --slurpfile metadata "$metadata" \
    --slurpfile git "$gitEntries" \
    --slurpfile gitRepos "$gitRepos" \
    '{
      version: $version,
      clojureVersion: $clojureVersion,
      javaVersion: $javaVersion,
      projectDir: $projectDir,
      definitionFiles: $definitionFiles,
      definitionHash: $definitionHash,
      aliases: $aliases,
      prepared: $prepared,
      userAliases: $userAliases,
      build: $build,
      test: $test,
      project: { group: $group, name: $name, version: $projectVersion },
      pom: $pom,
      outputs: $outputs,
      artifacts: $artifacts,
      metadata: $metadata,
      git: $git,
      gitRepos: $gitRepos
    }' >"$lockFile.tmp"
  mv "$lockFile.tmp" "$lockFile"
  echo "clojure-cli-purifier: wrote $lockFile ($(jq '.artifacts | length' "$lockFile") files, $(jq '.git | length' "$lockFile") git checkouts, $(jq '.outputs | length' "$lockFile") outputs)"
}

# Builds the environment of the lock into the store, keeps it alive with a
# GC root in the state directory, and prints its store path.
realizeEnv() {
  local lockFile=$1 state=$2
  mkdir -p "$state"
  nix-build "$PURIFIER_LIB/realize.nix" --arg lockFile "$lockFile" \
    --argstr nixpkgs "$PURIFIER_NIXPKGS" -o "$state/env" >/dev/null
  readlink -f "$state/env"
}

cmdClojure() {
  local root lockFile
  root=$(projectRoot)
  lockFile="$root/$lockName"
  [ -f "$lockFile" ] || die "$lockFile does not exist; run clojure-cli-purifier lock"
  if ! lockIsCurrent "$root" "$lockFile"; then
    echo "clojure-cli-purifier: $lockFile is out of date; the Clojure CLI resolves the usual way until clojure-cli-purifier lock renews it" >&2
    exec clojure "$@"
  fi

  local state="$root/.cpcache/clojure-cli-purifier" env
  env=$(realizeEnv "$lockFile" "$state")

  # The local repository is a writable tree of links into the store, and
  # the gitlibs directory holds writable copies of the checkouts, which a
  # git dependency that needs preparing writes into. Both are made anew
  # when the environment changes.
  local home="$state/home" gitlibs="$state/gitlibs"
  if [ "$(cat "$state/env.path" 2>/dev/null || true)" != "$env" ]; then
    chmod -R u+w "$home" "$gitlibs" 2>/dev/null || true
    rm -rf "$home" "$gitlibs" "$state/cache"
    mkdir -p "$home/.m2/repository" "$gitlibs"
    cp -rs --no-preserve=mode "$env/repository/." "$home/.m2/repository"
    # Maven Resolver rewrites the metadata records it reads, so those are
    # writable copies.
    find "$home/.m2/repository" -type l \( -name 'maven-metadata*.xml' -o -name resolver-status.properties \) \
      -exec cp --no-preserve=mode -L {} {}.tmp \; -exec mv {}.tmp {} \;
    cp -rL --no-preserve=mode "$env/gitlibs/." "$gitlibs"
    echo "$env" >"$state/env.path"
  fi

  # The JVMs find the local repository through user.home. The Clojure CLI
  # configuration of the user stays in effect. Git trusts the checkouts,
  # which the store owns.
  export GITLIBS="$gitlibs"
  export CLJ_CACHE="$state/cache"
  export CLJ_JVM_OPTS="-Duser.home=$home ${CLJ_JVM_OPTS:-}"
  export JAVA_OPTS="-Duser.home=$home ${JAVA_OPTS:-}"
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
  exec clojure "$@"
}

cmdPublish() {
  local repository="" dryRun=0
  while [ $# -gt 0 ]; do
    case $1 in
    --repository)
      [ $# -ge 2 ] || die "publish: --repository takes ID=URL"
      repository=$2
      shift
      ;;
    --dry-run) dryRun=1 ;;
    *) die "publish: unknown argument $1" ;;
    esac
    shift
  done

  local root lockFile
  root=$(projectRoot)
  lockFile="$root/$lockName"
  lockIsCurrent "$root" "$lockFile" || die "$lockFile is missing or out of date; run clojure-cli-purifier lock"
  [ "$(jq -r .pom "$lockFile")" != null ] || die "the build of the lock writes no POM, which publishing needs"

  local name version jar pom package
  name=$(jq -r .project.name "$lockFile")
  version=$(jq -r .project.version "$lockFile")
  jq -e --arg jar "$name-$version.jar" 'any(.outputs[]; (.path | split("/") | last) == $jar)' "$lockFile" >/dev/null ||
    die "the build of the lock makes no $name-$version.jar to publish"
  local projectDir
  projectDir=$(lockProjectDir "$lockFile")
  package=$(nix-build --no-out-link "$PURIFIER_LIB/package.nix" \
    --argstr nixpkgs "$PURIFIER_NIXPKGS" \
    --argstr src "$(sourceRootOf "$root" "$projectDir")" --argstr projectDir "$projectDir")
  jar="$package/share/java/$name-$version.jar"
  pom="$package/share/java/$name-$version.pom"

  local -a deploy=(clojure -Sdeps '{:deps {slipset/deps-deploy {:mvn/version "0.2.2"}}}'
    -X deps-deploy.deps-deploy/deploy :installer :remote :sign-releases? false
    :artifact "\"$jar\"" :pom-file "\"$pom\"")
  if [ -n "$repository" ]; then
    # The repository map is one EDN argument.
    deploy+=(:repository "{\"${repository%%=*}\" {:url \"${repository#*=}\"}}")
  fi
  if [ $dryRun = 1 ]; then
    echo "jar: $jar"
    echo "pom: $pom"
    printf '%q ' "${deploy[@]}"
    echo
    return
  fi
  "${deploy[@]}"
}

case ${1:-} in
lock)
  shift
  cmdLock "$@"
  ;;
clojure)
  shift
  cmdClojure "$@"
  ;;
publish)
  shift
  cmdPublish "$@"
  ;;
-h | --help | help)
  usage
  ;;
*)
  usage >&2
  exit 1
  ;;
esac
