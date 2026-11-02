# SPDX-License-Identifier: MIT
{
  pkgs,
  build,
  purifier,
}:
let
  original = builtins.fromJSON (builtins.readFile ./fixtures/hello/clojure-cli-purifier.lock.json);
  upstream = builtins.head (
    builtins.filter (
      entry: entry.path == "org/clojure/data.json/2.5.1/data.json-2.5.1.jar"
    ) original.artifacts
  );
  upstreamJar = purifier.fetchEntry { inherit pkgs; } upstream;
  provider =
    pkgs.runCommand "clojure-json-provider"
      {
        passthru.projections = purifier.jvmProjections {
          repository = provider;
          inherit (pkgs) runCommand python3;
        };
      }
      ''
        directory=$out/org/clojure/data.json/0.0.1
        mkdir -p "$directory"
        cp ${upstreamJar} "$directory/data.json-0.0.1.jar"
        cat > "$directory/data.json-0.0.1.pom" <<'POM'
        <project xmlns="http://maven.apache.org/POM/4.0.0">
          <modelVersion>4.0.0</modelVersion><groupId>org.clojure</groupId>
          <artifactId>data.json</artifactId><version>0.0.1</version>
        </project>
        POM
      '';
  withoutProvided = removeAttrs (
    original
    // {
      artifacts = builtins.filter (
        entry: !(pkgs.lib.hasPrefix "org/clojure/data.json/" entry.path)
      ) original.artifacts;
    }
  ) [ "contentHash" ];
  lockFile = builtins.toFile "clojure-cli-purifier.lock.json" (
    builtins.toJSON (
      withoutProvided
      // {
        contentHash = builtins.hashString "sha256" (builtins.toJSON withoutProvided);
      }
    )
  );
  consumer = build {
    src = ./fixtures/hello;
    inherit lockFile;
    projectDependencies = [ provider ];
  };
  checkedTests = consumer.tests.overrideAttrs (old: {
    buildPhase = ''
      trap 'status=$?; if [ "$status" -ne 0 ]; then find "$TMPDIR/java-tmp" -name "clojure-*.edn" -exec cat {} \;; fi; exit "$status"' EXIT
    ''
    + old.buildPhase;
  });

in
pkgs.runCommand "clojure-nix-composition" { passthru = { inherit provider consumer; }; } ''
  test -d ${checkedTests}
  ${consumer.packages.hello}/bin/hello > result
  grep -qx '{"hello":"Hello, Nix"}' result
  grep -qx '<p>purified</p>' result
  # Rewriting a foreign descriptor must not alter its archive bytes.
  clojureJar=$(find ${consumer.projections.maven}/org/clojure/clojure -name '*.jar')
  cmp ${consumer.repository}/org/clojure/clojure/1.12.3/clojure-1.12.3.jar "$clojureJar"
  test -n "$(find ${consumer.projections.maven}/local/greet -name '*-nix-*.jar')"
  touch $out
''
