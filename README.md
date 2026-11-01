# clojure-cli-purifier

A command and a Nix library that build Clojure projects of the
[Clojure CLI](https://clojure.org/reference/clojure_cli) (`deps.edn`
projects) in the Nix sandbox. The command records the files the Clojure CLI
wants to download in a lockfile, and Nix builds the project from that
lockfile, offline. You commit the lockfile, and no generated Nix files.

clojure-cli-purifier is one of the
[nix-purifiers](https://nix-purifiers.github.io).

- **A lockfile.** `clojure-cli-purifier lock` writes
  `clojure-cli-purifier.lock.json` at the project root. It holds every file
  the Clojure CLI downloads, by the URL it came from and its SHA-256, every
  git dependency with the commits and tags the CLI reads, and the build and
  test commands. It also names the jars the build produces, the POM it
  writes and the main class of an uberjar, so Nix knows every output when
  it evaluates.
- **Sandboxed builds.** `buildClojureCliProject` runs the locked build
  commands in the sandbox, and gives a package with the jars and the POM in
  `share/java`, and a launcher in `bin` for an uberjar with a main class.
- **The Clojure CLI on the locked downloads.** `clojure-cli-purifier clojure`
  runs the Clojure CLI offline, with a local Maven repository and a
  gitlibs directory that hold exactly the locked downloads.
- **Publishing what Nix built.** `clojure-cli-purifier publish` builds the
  package with Nix and deploys its jar and POM to Clojars or another Maven
  repository.

## How the lock is made

`clojure-cli-purifier lock` copies the project, or the source root that
holds it, to a temporary directory
and runs the Clojure CLI there with an empty local Maven repository, an
empty gitlibs directory (`GITLIBS`) and an empty user `deps.edn`. That is
the environment a sandboxed build has. It prepares the classpath of the
project and of each alias (`clojure -P -M:<alias>`), prepares the git
dependencies that need it (`clojure -X:deps prep`), and runs the build and
test commands. Everything the CLI, tools.build and the test runner
download lands in the empty repositories, and the lockfile records it:

- files from any Maven repository, Maven Central and Clojars included, and
  from the repositories `deps.edn` adds with `:mvn/repos`. Each file is
  locked with the URL of the repository Maven Resolver recorded for it,
  which is a mirror's URL when `~/.m2/settings.xml` configures a mirror;
- version ranges and SNAPSHOT versions. Maven Resolver picks those from
  repository metadata, whose content changes over time at its URL, so the
  lockfile holds the content the lock run read, and the build resolves to
  the versions the lock run picked. A SNAPSHOT file is locked at its
  timestamped URL;
- git dependencies, given by `:git/sha` alone or with `:git/tag`. Each
  checkout is locked with the hash `nix-prefetch-git` reports for it. The
  Clojure CLI expands a short commit and checks a tag in a bare clone of
  the repository, so the lockfile also holds the commit objects and the
  tags the CLI reads, and the Nix build rebuilds the bare clone from them
  and from the checkout. A rebuilt commit has exactly the locked hash,
  because a commit object names its tree and parents by hash;
- the dependencies a POM chooses by architecture. The lock run resolves the
  project once more for each Linux architecture the flake builds for
  (`amd64` and `aarch64`), with the matching `os.arch`;
- `:local/root` dependencies. They are not downloads: the build takes them
  from the source. A local dependency outside the project, such as a
  sibling directory in a repository with several projects, needs a source
  root that holds both: `lock --source DIR` names it, the lockfile records
  where the project lies in it, and the Nix build takes that directory as
  `src` with `projectDir` naming the project.

Maven Resolver reads its proxy only from `settings.xml`. The lock run uses
the `~/.m2/settings.xml` of the user, with its proxies, mirrors and
repository credentials, and otherwise writes one with the proxy of
`https_proxy`.

The lock is current while `deps.edn`, `build.clj`, every other `deps.edn`
of the source root and the version of the Clojure CLI are unchanged. `clojure-cli-purifier lock` leaves a current lockfile alone, and
`--force` relocks regardless.

## Use

Lock the project from its root, naming the build and test commands, and
commit the lockfile:

```zsh
nix run github:nix-purifiers/clojure-cli-purifier -- lock --build '-T:build uber' --test '-M:test'
```

`--build` and `--test` may repeat. Without `--build`, the build is the
`uber` function of `build.clj`, or its `jar` function. `--alias :name`
limits the aliases the lock prepares, which are all aliases of `deps.edn`
by default. Each option replaces its part of an existing lockfile, and a
relock keeps every part no option names.

The flake's `overlays.default` adds `buildClojureCliProject` to a package
set, and a package written for `callPackage` takes it by name, like any
other builder:

```nix
# package.nix
{ buildClojureCliProject }:
(buildClojureCliProject { src = ./.; }).package
```

```nix
{
  inputs.clojure-cli-purifier.url = "github:nix-purifiers/clojure-cli-purifier";
  inputs.nixpkgs.follows = "clojure-cli-purifier/nixpkgs";

  outputs = { nixpkgs, clojure-cli-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          clojure-cli-purifier.overlays.default
          (final: prev: { hello = final.callPackage ./package.nix { }; })
        ];
      };
    in
    {
      packages.${system}.default = pkgs.hello;
    };
}
```

`buildClojureCliProject` takes `src`, which is the project root or the
source root the lock was made with. `projectDir` names the directory of
the project in `src`. It is `"."` by default, and it must match the
lockfile. `lockFile` defaults to the lockfile in the project directory.
`doCheck` runs the test commands of the lock after the build. `jdk`
defaults to the headless JDK of the major version the lock was made with.
`fetchurl` and `fetchgit` replace the fetchers of nixpkgs, for credentials
or a local mirror. `srcFilter` filters the source before it goes into the
store.

It returns `package` (also as `packages.<name>`), `repository` and
`gitlibs` (the local Maven repository and the gitlibs directory of the
lock), `lock`, `jdk` and `clojure`. `package.artifacts."<file>"` is each
file of the package, such as `artifacts."hello-1.0.0-standalone.jar"`,
known from the lockfile before anything is built.

### Private repositories

A Maven repository that needs credentials takes them through `fetchurl`,
for example nixpkgs' `fetchurl` with `netrcPhase`. A git dependency over
ssh needs the credentials of the user, which the sandbox does not have.
`builtins.fetchGit` fetches at evaluation time with the ssh agent and the
git configuration of the user, and still checks the locked hash:

```nix
buildClojureCliProject {
  src = ./.;
  fetchgit = args: builtins.fetchGit {
    inherit (args) url rev;
    narHash = args.hash;
  };
}
```

## The Clojure CLI on the locked downloads

```zsh
nix run github:nix-purifiers/clojure-cli-purifier -- clojure -M:test
```

`clojure-cli-purifier clojure` builds the local Maven repository and the
gitlibs directory of the lockfile into the store, keeps them alive with a
GC root under `.cpcache/clojure-cli-purifier`, and runs the Clojure CLI on
them. Your user `deps.edn` stays in effect, and `lock --user-aliases`
also locks its aliases, so that tools you keep there, such as an nREPL
alias, run offline too. When the lockfile is out of date, the command
warns and runs the Clojure CLI the usual way until `lock` renews it.

## Publishing

```zsh
CLOJARS_USERNAME=… CLOJARS_PASSWORD=… \
  nix run github:nix-purifiers/clojure-cli-purifier -- publish
```

`publish` builds the package with Nix and deploys the jar named
`<artifactId>-<version>.jar` and the POM the build wrote, with
[deps-deploy](https://github.com/slipset/deps-deploy). Nothing is compiled
outside the sandbox. `--repository ID=URL` deploys to another Maven
repository, with the credentials of the server of the same id in
`~/.m2/settings.xml`, and `--dry-run` prints what it would deploy.

## Limits

- **Downloads outside the Clojure CLI.** A build script that downloads a
  file itself, rather than through a dependency, fails in the sandbox,
  because the lock records only what the Clojure CLI and Maven Resolver
  fetch.
- **Git files changed by attributes.** The Nix build rebuilds each commit
  from the files of its checkout. A repository whose checkout differs from
  its commit, such as one with Git LFS files, cannot rebuild the commit,
  and the lock run refuses it with a message that names it.

## Credit

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo). The lockfile and the
interactive mode follow
[sbt-purifier](https://github.com/nix-purifiers/sbt-purifier).

## License

MIT
