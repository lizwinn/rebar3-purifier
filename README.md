# rebar3-purifier

rebar3-purifier makes Nix the dependency backend of a rebar3 build. It
records the files rebar3 wants to download in a lockfile, so that Nix can
build the project in its sandbox. You do not commit any generated Nix
files to your repository.

- **A lockfile.** `rebar3-purifier lock` writes `rebar3-purifier.lock.json`
  next to `rebar.config`. It lists every download of the build: the Hex
  package tarballs of the dependencies and plugins of every profile, by URL
  and SHA-256, and a checkout of every git dependency and git plugin. It
  also lists what the build produces: the project's applications, its relx
  releases, its escript and its Hex packages.
- **Sandboxed builds.** `buildRebar3Project`, which the flake's overlay adds
  to a package set, builds from the lockfile with no network access.
  `apps.<name>`, `releases.<name>`, `escripts.<name>` and
  `hexPackages.<name>` are the outputs.
- **Interactive rebar3 on the locked downloads.** The flake's `rebar3` runs
  the real rebar3. In a project with a current lockfile, it first fetches
  the locked downloads through Nix, so `rebar3 compile`, `rebar3 eunit`,
  `rebar3 ct`, `rebar3 shell` and `rebar3 release` read the same files the
  Nix build reads, offline. Editors and language servers that run rebar3,
  such as the Erlang Language Platform, work the same way.
- **Publishing what Nix built.** `rebar3-purifier publish` builds the
  project's Hex packages through Nix and uploads those tarballs to Hex.

rebar3-purifier is one of the [nix-purifiers](https://nix-purifiers.github.io).
Its design follows sbt-nix-backend, the first of them: the tool keeps
planning the build, a lock run with empty caches records what the tool
downloads, Nix builds from the lockfile, and the interactive tool reads
the same locked downloads. The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).

## How the lock is made

`rebar3-purifier lock` copies the project to
`_build/rebar3-purifier/lock-run` and runs `rebar3 compile`,
`rebar3 as test compile` and `rebar3 as prod compile` there, with an empty
home and cache, and with the network. Your global rebar3 configuration stays
in effect, for the Hex repositories and credentials it may hold. Every Hex
tarball rebar3 downloads, for dependencies and plugins alike, lands in the
empty cache, and every git repository it clones lands under `_build`. The
lockfile gets two kinds of entry:

- **Hex tarballs.** Each tarball, at its path in rebar3's cache
  (`hex/<repository>/packages/<name>-<version>.tar`) and at the tarball URL
  of its repository. The default repository is `https://repo.hex.pm`, or
  `HEX_CDN` when it is set; an organization is `/repos/<organization>`
  under it, and another repository comes from the `hex` section of
  `rebar.config` or of your global configuration.
- **Git checkouts.** For each git dependency, git plugin and `git_subdir`
  dependency, a plain checkout of the commit rebar3 checked out, with the
  NAR hash `nix-prefetch-git` reports, the raw commit object, and the tags
  and branches rebar3 clones by. An SSH URL is recorded as the HTTPS URL of
  the same host, since the Nix sandbox has no SSH keys.

When the lock run resolved dependencies that `rebar.lock` did not hold, it
writes the new `rebar.lock` back to the project, and says so; commit it with
the lockfile. The lockfile also records the files that define the
dependencies (`rebar.config`, `rebar.config.script`, `rebar.lock` and the
`rebar.config` of each application). `rebar3-purifier lock` relocks only
when one of them changed since the lockfile was written, and
`rebar3-purifier relock` relocks regardless. `--profile <name>` adds a
profile to the three it always locks. A relock that finds the same
downloads writes the same bytes.

## Use

Lock the project, from its directory:

```zsh
nix run github:nix-purifiers/rebar3-purifier -- lock
```

Commit `rebar3-purifier.lock.json` (and `rebar.lock`, when the lock run
updated it). The flake's `overlays.default` adds `buildRebar3Project` to a
package set, and a package written for `callPackage` takes it by name, like
any other builder:

```nix
# package.nix
{ buildRebar3Project }:
(buildRebar3Project { src = ./.; }).releases.my_app
```

```nix
{
  inputs.rebar3-purifier.url = "github:nix-purifiers/rebar3-purifier";
  inputs.nixpkgs.follows = "rebar3-purifier/nixpkgs";

  outputs = { nixpkgs, rebar3-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          rebar3-purifier.overlays.default
          (final: prev: { my_app = final.callPackage ./package.nix { }; })
        ];
      };
    in
    {
      packages.${system}.my_app = pkgs.my_app;
    };
}
```

`buildRebar3Project` returns:

- `apps.<name>`, each of the project's applications, compiled, in
  `lib/<name>` (its `ebin`, `priv` and `include`);
- `releases.<name>`, each relx release, built with the `prod` profile, with
  its start script linked as `bin/<name>` and on its `PATH` the tools the
  script needs;
- `escripts.<name>`, the escript, when `rebar.config` sets
  `escript_main_app` or `escript_name`;
- `hexPackages.<name>`, the Hex package tarball of each application, when
  `rebar3_hex` is among the plugins;
- `all`, one derivation with every output, which the others link into, and
  `cache`, the tree of the locked downloads.

`nix/lib/build-rebar3-project.nix` documents the arguments. `beamPackages`
replaces the BEAM package set; the default is the one of the OTP release
the lock was made with, when nixpkgs has it. `fetchurl` and `fetchgit`
replace the fetchers, for mirrors or for credentials to private
repositories. `releaseProfile` is the profile releases are built with.
`doCheck` runs `rebar3 eunit`, and `rebar3 ct` when the project has common
test suites. `buildInputs`, `nativeBuildInputs` and `srcFilter` do what
their names say.

Before rebar3 runs, the build checks the lockfile against the source. When
a file that defines the dependencies changed since the lock, or when
`rebar.lock` names a dependency the lockfile has no download for, the build
stops and says to run `rebar3-purifier lock` (or `relock`) and commit the
lockfile.

## Interactive rebar3

`nix develop github:nix-purifiers/rebar3-purifier` gives a shell with the
flake's `rebar3`, the Erlang tools and `rebar3-purifier`. Run rebar3 as
usual. In a project with a current lockfile, rebar3 first builds the
lockfile's cache tree through Nix, under one GC root at
`_build/rebar3-purifier/cache-root`, and runs with:

- `REBAR_CACHE_DIR` at `_build/rebar3-purifier/cache`, a writable copy of
  the tree: links to the locked tarballs, with the package index and etags
  rebar3 reads beside them;
- `HEX_CDN` at an address that refuses connections, so rebar3 takes every
  Hex tarball from the cache;
- git redirected, with `url.<repository>.insteadOf`, from each locked git
  URL to a repository in the store that holds the locked commit.

A dependency that is not in the lockfile then fails to fetch. A project
without a lockfile resolves the usual way. When a file that defines the
dependencies changed since the lockfile was written, rebar3 warns and
resolves the usual way until `rebar3-purifier lock` renews the lockfile.
`REBAR3_PURIFIER=0` turns interactive mode off.

## Publishing

`rebar3-purifier publish` builds the Hex package of each application, or
of the ones you name, through Nix from the project directory, with a GC
root under `_build/rebar3-purifier/publish`, and uploads those tarballs to
the Hex API with rebar3's own Hex client. The lockfile has to be current.
`HEX_API_KEY` holds the key to publish with, `HEX_API_URL` replaces the
default API (`https://hex.pm/api`), and `HEX_ORGANIZATION` publishes into an
organization. `--dry-run` builds the tarballs and prints their paths.

## Decisions

- **The package index is generated, not locked.** rebar3 reads the Hex
  registry for every Hex dependency, even one `rebar.lock` pins, before it
  takes the cached tarball. Registry records change with every release, so
  they cannot be locked by hash. Each Hex tarball carries the checksums and
  requirements the registry holds for its version, so the build writes the
  index rebar3 reads (`hex/packages.idx`, format 7) from the locked
  tarballs, and the etag file beside each tarball. A rebar3 that changes
  the index format discards the index, and the fixture builds then fail.
- **Git repositories are rebuilt from plain checkouts.** rebar3 clones git
  dependencies and checks out a commit, a tag or a branch, so it needs a
  repository. A checkout with its `.git` directory does not hash the same
  way twice, since git packs objects differently from run to run. The
  lockfile pins a plain checkout and records the raw commit object, and the
  shared [purifier](https://github.com/nix-purifiers/purifier) library
  rebuilds a shallow `.git` directory from them and checks that the commit
  hashes to the locked revision. rebar3-purifier makes a bare repository of
  it with the tags and branches rebar3 clones by.
- **Downloads are fetched by the shared purifier library,** whose entry
  kinds the lockfile uses for every download.
- **No `REBAR_OFFLINE`.** rebar3 3.28's own offline mode crashes on Hex
  dependencies. The sandbox has no network, and interactive mode points Hex
  at a closed port, so rebar3 falls back to the cached tarballs on its own.
- **Versions from git are pinned.** An application whose `.app.src` takes
  its version from git (`{vsn, git}`) cannot compute it in the sandbox,
  which has no `.git` directory. The lock run records the version rebar3
  computed, and the build writes it into its copy of the `.app.src`. Relock
  to record a new version.
- **Erlang and rebar3 come from nixpkgs.** The lockfile records the OTP
  release and the rebar3 version the lock was made with, for reference.
- **The user's global rebar3 configuration** is in effect during the lock
  run, for Hex repositories and credentials, but not in the sandbox. A
  plugin that only the global configuration names is downloaded by the
  lock run, and the build does not load it.

## Limits

- **Downloads outside rebar3's fetchers,** such as a plugin or a build hook
  that downloads files itself, fail in the sandbox. C libraries for NIFs and
  port drivers come from `buildInputs`, not from the lockfile.
- **Hex repositories that need credentials:** the lock run downloads their
  tarballs with your credentials and adds them to the Nix store, where the
  build finds them. Another machine needs a `fetchurl` with credentials.
- **Releases** run with the `prod` profile by default; pass
  `releaseProfile` for another.

## Projects it was tried on

Besides the fixtures in `tests/fixtures`, `tests/real-world.sh` works through
real projects pinned to a commit, in CI on x86_64-linux and aarch64-linux:
it locks each one, builds its escript in the Nix sandbox and runs it,
compiles it with the offline rebar3, and relocks to check that the lockfile
is reproduced byte for byte.

- [erlang_ls](https://github.com/erlang-ls/erlang_ls) at `3a79185`: two
  applications, Hex dependencies (one renamed), git dependencies by commit
  and by tag, Hex plugins and a git plugin by branch, and an escript.
- [elvis](https://github.com/inaka/elvis) at `c4ca8fa`: Hex dependencies,
  Hex plugins including rebar3_hex with an ex_doc documentation provider,
  and an escript.

## Development

`nix flake check` builds the fixtures and runs the unit tests of the
`rebar3-purifier` command. The scripts in `tests/` need Nix and the network,
and take a toolchain built by `nix build .#toolchain --out-link toolchain`:
`tests/interactive.sh toolchain` checks interactive mode,
`tests/negative.sh toolchain` the common mistakes,
`tests/publish.sh toolchain` publishing, and
`tests/real-world.sh toolchain <project>` works through a real project.
`docs/development` describes the code.
