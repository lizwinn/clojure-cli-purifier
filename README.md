# clojure-cli-purifier

A command and a Nix library that build Clojure projects of the
[Clojure CLI](https://clojure.org/reference/clojure_cli) (`deps.edn`
projects) in the Nix sandbox. The command records the files the Clojure CLI
downloads in a lockfile, and Nix builds the project from that lockfile,
offline. The project commits the lockfile, and no generated Nix files.

clojure-cli-purifier is one of the
[nix-purifiers](https://nix-purifiers.github.io), and it meets their
[contract](https://github.com/nix-purifiers/purifier/blob/main/CONTRACT.md).

## Quickstart

Lock the project from its root, naming the build and test commands, and
commit `clojure-cli-purifier.lock.json`:

```zsh
nix run github:nix-purifiers/clojure-cli-purifier -- lock --build '-T:build uber' --test '-M:test'
```

Then build it with the library of the flake:

```nix
{
  inputs.clojure-cli-purifier.url = "github:nix-purifiers/clojure-cli-purifier";
  inputs.nixpkgs.follows = "clojure-cli-purifier/nixpkgs";

  outputs = { nixpkgs, clojure-cli-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      project = clojure-cli-purifier.lib.clojure-cli-purifier.buildClojureCliProject {
        inherit pkgs;
        src = ./.;
      };
    in
    {
      packages.${system}.default = project.packages.hello;
      checks.${system}.tests = project.tests;
    };
}
```

`buildClojureCliProject` takes these arguments:

- `pkgs` is the package set the build runs with.
- `src` is the project root, or the source root the lock was made with.
- `projectDir` names the directory of the project in `src`. It is `"."` by
  default, and it must match the lockfile.
- `lockFile` is the lockfile. It defaults to `clojure-cli-purifier.lock.json`
  in the project directory.
- `fetchers` replaces fetchers of nixpkgs, for credentials or a mirror. The
  [purifier](https://github.com/nix-purifiers/purifier) library's
  `fetchEntry` and `tree` take it.
- `jdk` defaults to the headless JDK of the major version the lock was made
  with.
- `srcFilter` filters the source before it goes into the store.

The result has these attributes:

- `packages.<name>` holds the jars and the POM in `share/java`, and a
  launcher in `bin` for each uberjar with a main class. `<name>` is the
  artifact id of the POM the build writes, or the name of the project
  directory.
- `tests` is the same build, which also runs the test commands of the lock.
- `release` holds `<artifactId>-<version>.jar` and its POM, which `publish`
  deploys.
- `fetches` lists the Maven files and git checkouts of the build as entries
  of the purifier library.
- `repository` and `gitlibs` are the local Maven repository and the
  gitlibs directory of the lock.

The lockfile names the jars, the POM and the main classes the build
produces, so Nix knows every attribute and every output at evaluation,
without import-from-derivation.

`lib.clojure-cli-purifier.readLock { src, projectDir ? ".", lockFile ? ... }`
reads the lockfile into the shape that every nix-purifier gives, for tools
such as SBOM generators. Its `entries` are the Maven files, the recorded
repository metadata and the git checkouts, and its `outputs` name the
package. Its `problems` list why the lockfile cannot be used, each with
the command that fixes it. The builder fails evaluation with them.

A project can keep its build external, with the lockfile outside its
source, so that a packaging flake builds a project its author does not
change. The flake passes the lockfile as `lockFile`. Every command takes
`--lockfile PATH` or the environment variable
`CLOJURE_CLI_PURIFIER_LOCKFILE`, which a dev shell can set to the same
path. The flag takes precedence over the variable.

## Everyday loop

`clojure-cli-purifier prefetch` builds the downloads of the lockfile into
the Nix store, and links `.clojure-cli-purifier/bin/clojure` beside the
lockfile. With that directory first on `PATH`, the project's own `clojure`
commands run on the locked downloads:

```zsh
clojure-cli-purifier prefetch
export PATH="$PWD/.clojure-cli-purifier/bin:$PATH"
clojure -M:test
clojure -T:build uber
```

With [direnv](https://direnv.net), an `.envrc` with
`PATH_add .clojure-cli-purifier/bin` sets the same `PATH`. We recommend
adding `.clojure-cli-purifier/` to `.gitignore`.

To add or upgrade a dependency, edit `deps.edn`, then run
`clojure-cli-purifier lock` and `clojure-cli-purifier prefetch`. A relock
keeps the build and test commands of the lockfile. `--build`, `--test`,
`--alias :name` and `--user-aliases` each replace their part of the
lockfile.

A relock also keeps the versions the lockfile chose for version ranges and
SNAPSHOTs, from the repository metadata it recorded.
`clojure-cli-purifier update` resolves them anew, for every library or for
the named ones:

```zsh
clojure-cli-purifier update org.clojure/core.memoize
```

The Clojure CLI has no update command of its own. A version that deps.edn
names exactly changes when deps.edn does, and a git dependency changes
when its `:git/sha` does.

The user `deps.edn` stays in effect. `lock --user-aliases` also locks its
aliases, so that tools kept there, such as an nREPL alias, run offline too.

`clojure-cli-purifier publish` builds the `release` with Nix and deploys its
jar and POM with [deps-deploy](https://github.com/slipset/deps-deploy).
Nothing is compiled outside the sandbox. The default repository is
Clojars, with `CLOJARS_USERNAME` and `CLOJARS_PASSWORD`.
`--repository ID=URL` deploys to another Maven repository, with the
credentials of the server of the same id in `~/.m2/settings.xml`.
`--dry-run` prints what it would deploy.

## Offline work

After a prefetch, `clojure` needs no network. The Maven repository and the
gitlibs directory under `.clojure-cli-purifier` hold exactly the locked
downloads, the git dependencies that need preparing are prepared, and the
JDK and the Clojure CLI come from the store. `.clojure-cli-purifier/env` is
a garbage-collector root, so `nix-collect-garbage` keeps the downloads
while it exists.

The `conformance-offline` check runs the tests, a SNAPSHOT, a version range
and an uberjar build of a fixture after a prefetch, in the Nix sandbox,
which has no network.

## Editor

[clojure-lsp](https://clojure-lsp.io) computes the classpath with
`clojure -Spath`, so it reads the locked downloads when the editor's
environment has `.clojure-cli-purifier/bin` first on `PATH`, such as
through direnv. In a project with a `bb.edn`, clojure-lsp asks babashka for
the classpath, and `.lsp/config.edn` points it at `deps.edn`:

```clojure
{:project-specs [{:project-path "deps.edn"
                  :classpath-cmd ["clojure" "-A:test" "-Spath"]}]}
```

clojure-lsp analyzes the jars on the classpath, which hold the Clojure
sources, and needs no other download.

## Errors and fixes

| Message | Fix |
| --- | --- |
| `the project definition in … changed after … was made; run clojure-cli-purifier lock` | Run `clojure-cli-purifier lock`. |
| `… does not match its contentHash, so it was edited after the lock run` | Run `clojure-cli-purifier lock --force`. |
| `… is not a JSON object, so it is not a clojure-cli-purifier lockfile` | Run `clojure-cli-purifier lock --force`. |
| `… has lock format version …` | Run `clojure-cli-purifier lock --force`. |
| `… was made with Clojure CLI …` | Run `clojure-cli-purifier lock`, with the clojure-cli-purifier of the package set that builds the project. |
| `the Clojure CLI tried to download something … does not hold` | Run `clojure-cli-purifier lock`, then `clojure-cli-purifier prefetch`. |
| `… changed after the last prefetch` | Run `clojure-cli-purifier prefetch`. |
| `hash mismatch in fixed-output derivation` | The server changed a file under its URL. Run `clojure-cli-purifier lock --force`. |

The builder refuses an invalid lockfile at evaluation, and the commands
refuse it before they run anything.

## Sources supported and refused

`clojure-cli-purifier lock` copies the project, or the source root that
holds it, to a temporary directory. It runs the Clojure CLI there with an
empty local Maven repository, an empty gitlibs directory (`GITLIBS`) and an
empty user `deps.edn`, which is the environment of a sandboxed build. It
prepares the classpath of the project and of each alias, prepares the git
dependencies that need it (`clojure -X:deps prep`), and runs the build and
test commands. The lockfile records every download:

- **Maven repositories.** Files from Maven Central, Clojars and the
  repositories `deps.edn` adds with `:mvn/repos` are supported. Each file
  is locked by the URL of its repository and its SHA-256.
- **Mirrors.** `lock --mirror ID=URL` downloads the files of the repository
  `ID` from a mirror during the lock run. The lockfile records the
  repository URL, and the mirror as a fallback. The mirrors of
  `~/.m2/settings.xml` are recorded the same way.
- **Version ranges and SNAPSHOT versions.** Maven Resolver picks these from
  repository metadata, whose content changes at its URL, so the lockfile
  holds the metadata the lock run read. The build resolves to the versions
  the lock run picked. A SNAPSHOT file is locked at its timestamped URL.
- **Git dependencies.** Dependencies given by `:git/sha` alone or with
  `:git/tag` are supported, including those that need preparing. The
  Clojure CLI expands a short commit and checks a tag in a bare clone, so
  the lockfile also holds the commit objects and tags the CLI reads. The
  Nix build rebuilds the bare clone from them, and each rebuilt commit has
  exactly the locked hash.
- **Dependencies chosen by architecture.** The lock run resolves the
  project once more for each Linux architecture the flake builds for, with
  the matching `os.arch`.
- **Local dependencies.** A `:local/root` dependency comes from the source.
  A local dependency outside the project needs a source root that holds
  both: `lock --source DIR` names it, and the Nix build takes that
  directory as `src`, with `projectDir` naming the project.
- **Downloads outside the Clojure CLI** are refused. A build script that
  downloads a file itself fails in the sandbox, because the lock records
  only what the Clojure CLI and Maven Resolver fetch.
- **Git files changed by attributes** are refused. A repository whose
  checkout differs from its commit, such as one with Git LFS files, cannot
  rebuild the commit, and the lock run names it.

Maven Resolver reads its proxy only from `settings.xml`. The lock run uses
`~/.m2/settings.xml` with its proxies, mirrors and credentials, and
otherwise writes one with the proxy of `https_proxy`. A Maven repository
that needs credentials in the Nix build takes them through
`fetchers.fetchurl`. A git dependency over ssh can be fetched at evaluation
with the user's ssh agent, and the locked hash still applies:

```nix
buildClojureCliProject {
  inherit pkgs;
  src = ./.;
  fetchers.fetchgit = args: builtins.fetchGit {
    inherit (args) url rev;
    narHash = args.hash;
  };
}
```

## Examples

CI locks and builds [honeysql](https://github.com/seancorfield/honeysql)
at commit `1cc6bbe`, as an example of a library with git dependencies and
a test suite. Its lockfile lies in `tests/real-world/honeysql`, outside
honeysql's source. The `real-world-honeysql` check builds the library and
runs its tests in the sandbox, and the `conformance-relock` CI job relocks
it.

On one machine, through Google's Maven Central mirror, locking honeysql
took 67 seconds and included its test run, and a relock after a dependency
change took 78 seconds. honeysql's `build.clj` runs under babashka, so its
lock names `--test '-X:test'` and no build.

The fixtures in `tests/fixtures` are small examples of the other cases:
Maven Central and Clojars dependencies, a local dependency, git
dependencies by tag and short sha, a version range, a SNAPSHOT, and a
repository with several projects.

This section names a few projects that CI uses. It is not a list of the
projects the purifier has been tried on or works with.

## Credits

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo). The lockfile and the
interactive mode follow
[sbt-purifier](https://github.com/nix-purifiers/sbt-purifier).

clojure-cli-purifier is MIT licensed; see [LICENSE](LICENSE).
