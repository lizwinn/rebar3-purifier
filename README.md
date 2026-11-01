# rebar3-purifier

rebar3-purifier makes Nix the dependency backend of a rebar3 build. It
records the files rebar3 wants to download, so that Nix can build the
project in its sandbox, and it points the everyday rebar3 at the same
downloads. You do not commit any generated Nix files to your repository.

rebar3-purifier is one of the [nix-purifiers](https://nix-purifiers.github.io),
which share one interface. It supports x86_64-linux and aarch64-linux.

## Quickstart

Lock the project, from its directory:

```zsh
nix run github:nix-purifiers/rebar3-purifier -- lock
```

This writes `rebar3-purifier.lock.json` next to `rebar.config`, and adds to
`rebar.lock` what it did not hold. Commit both. The overlay of the flake adds
one attribute to a package set, the scope `rebar3-purifier`. The scope holds
the builder `buildRebar3Project` beside the command and the toolchain. A
package written for `callPackage` takes the scope by name:

```nix
# package.nix
{ rebar3-purifier }:
(rebar3-purifier.buildRebar3Project { src = ./.; }).packages.release-my_app
```

Build it from a flake:

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
      packages.${system}.default = pkgs.my_app;
      checks.${system}.tests = (pkgs.rebar3-purifier.buildRebar3Project { src = ./.; }).tests;
    };
}
```

`buildRebar3Project { src, lockFile ? ..., fetchers ? { }, ... }` returns:

- `packages.default`, one derivation with every output;
- `packages.app-<name>`, each application of the project, compiled, in
  `lib/<name>` (its `ebin`, `priv` and `include`);
- `packages.release-<name>`, each relx release, built with the `prod`
  profile, with its start script as `bin/<name>` and on its `PATH` the tools
  the script needs;
- `packages.escript-<name>`, the escript, when `rebar.config` sets
  `escript_main_app` or `escript_name`;
- `tests`, `rebar3 eunit` and, when the project has common test suites,
  `rebar3 ct`, run in the sandbox;
- `release`, the Hex package tarballs, which `rebar3-purifier publish`
  uploads;
- `fetches`, the entries of the shared
  [purifier](https://github.com/nix-purifiers/purifier) library that the
  build fetches, for SBOM, license and vulnerability tools;
- `cache`, the tree of the locked downloads.

Every attribute name is known at evaluation time, with no
import-from-derivation. `fetchers` replaces the fetchers of the library,
for a company mirror or for credentials: `fetchers.fetchurl` is a
`fetchurl` with them. `buildRebar3Project.override` replaces the packages the
builder takes, and `rebar3-purifier.overrideScope` replaces what the
packages of the scope share. `lib.rebar3-purifier.readLock { src,
lockFile ? ..., rebarLock ? ... }` reads the lockfiles into the lock in
memory that the nix-purifiers share.

The other arguments are `beamPackages` (the default is the one of the OTP
release the lock was made with, when nixpkgs has it), `cli`,
`releaseProfile`, `buildInputs`, `nativeBuildInputs` and `srcFilter`.
`nix/lib/build-rebar3-project.nix` documents them.

We recommend committing both `rebar3-purifier.lock.json` and `rebar.lock`
to the repository. The builder and the commands look for them there.

A build can instead keep the lockfiles outside the repository, for a
project whose committed lockfiles are missing or stale. The flake that
calls the builder passes `lockFile`, and `rebarLock` when it also keeps a
copy of `rebar.lock`, and the build uses them in place of the copies in
`src`. The commands take `--lockfile <path>` and `--tool-lockfile <path>`,
or the variables `REBAR3_PURIFIER_LOCKFILE` and
`REBAR3_PURIFIER_TOOL_LOCKFILE`. With either, `lock` and `update` write
the lockfile at that path and leave the copy in the tree as it is, and
`lock` starts from the copy of `rebar.lock` in the tree while the one
outside does not exist.

## Development loop

`nix develop github:nix-purifiers/rebar3-purifier` gives a shell with
`rebar3`, the Erlang tools, `elp` and `rebar3-purifier`. Run rebar3 as
usual: `rebar3 compile`, `rebar3 eunit`, `rebar3 ct`, `rebar3 shell`,
`rebar3 release`. In a project with a lockfile, `rebar3` first builds the
cache tree of the lockfile through Nix, and runs with:

- `REBAR_CACHE_DIR` at `_build/rebar3-purifier/cache`, a writable copy of
  the tree: links to the locked tarballs, with the package index and etags
  rebar3 reads beside them;
- `HEX_CDN` at an address that refuses connections, so rebar3 takes every
  Hex tarball from the cache;
- git redirected, with `url.<repository>.insteadOf`, from each locked git
  URL to a repository in the store that holds the locked commit.

A dependency that is not in the lockfile fails to fetch, with the message
of rebar3. A project without a lockfile resolves the usual way.
`REBAR3_PURIFIER=0` turns interactive mode off.

The commands:

- `rebar3-purifier lock` runs rebar3 in a copy of the project with empty
  caches and the network, on the `default`, `test` and `prod` profiles
  (`--profile <name>` adds one), and records what rebar3 downloaded and
  what the build produces. It keeps the resolution of `rebar.lock`. A
  relock of an unchanged project writes the same bytes.
- `rebar3-purifier update [<package>...]` runs `rebar3 upgrade` on every
  dependency, or on the named ones, and then locks.
- `rebar3-purifier prefetch` is described under Working offline.
- `rebar3-purifier publish [--dry-run] [<application>...]` builds the
  `release` through Nix and uploads those tarballs to Hex with the Hex
  client of rebar3. `HEX_API_KEY` holds the key, `HEX_API_URL` replaces the
  default API (`https://hex.pm/api`), and `HEX_ORGANIZATION` publishes into
  an organization. `--dry-run` builds the tarballs and prints their paths.

rebar3 has a plugin mechanism, and rebar3-purifier is a separate command
that runs beside it. `lock` runs rebar3 itself in a copy of the project
with empty caches, and the `rebar3` of the toolchain sets the Hex and git
environment before rebar3 starts. A plugin runs inside rebar3, after it has
read its cache and configuration, so it cannot do either.

## Working offline

`rebar3-purifier prefetch` realizes in the Nix store everything the
lockfile lists for the current system: the Hex tarballs and the git
checkouts of every profile, and the toolchain, which holds Erlang, rebar3
and the Erlang Language Platform (`elp`). It keeps them alive with
garbage-collector roots in `.rebar3-purifier-gcroots` beside the
lockfile, which `.gitignore` should list. After a prefetch, `rebar3 compile`,
`rebar3 eunit`, `rebar3 release` and the editor work with the network cut
off.

## Editor

The toolchain has `elp`, the
[Erlang Language Platform](https://whatsapp.github.io/erlang-language-platform/),
which loads the project by running rebar3. Run your editor inside
`nix develop`, or put the toolchain on its `PATH`, and `elp` finds the
rebar3 of the toolchain, which reads the locked downloads. After a
prefetch the editor needs no network.

## Troubleshooting

Every lockfile problem stops the build and the commands with a message that
names the command that fixes it, and the same messages appear at Nix
evaluation.

| Problem | Message names |
| --- | --- |
| The lockfile does not exist | `rebar3-purifier lock` |
| The lockfile is not valid JSON, or not a rebar3-purifier lockfile | `rebar3-purifier lock` |
| The lockfile has another format version | `rebar3-purifier lock` |
| The lockfile was changed after `lock` wrote it (its `contentHash` differs) | `rebar3-purifier lock` |
| `rebar.config`, `rebar.lock` or the `rebar.config` of an application changed since the lock | `rebar3-purifier lock` |
| `rebar.lock` names a dependency that has no download | `rebar3-purifier lock` |
| A download has another hash than the lockfile records | the build fails in the fetcher, which names the hash |

To move dependencies to newer releases, run `rebar3-purifier update`.

## Supported language repositories

The purifier fetches Hex packages from `https://repo.hex.pm`, from
`HEX_CDN` or `HEX_MIRROR`, from `hexpm:<organization>`, and from a
repository that `rebar.config` or your global rebar3 configuration names
under `hex`. The checksum of a Hex package of `rebar.lock` is its outer
checksum, the SHA-256 of the tarball, and the build checks the download
against it.

It fetches git dependencies and `git_subdir` dependencies by commit, tag or
branch, and git plugins. The lockfile records the hash of the checkout and
the raw commit object, and the build rebuilds the repository from them. An
SSH URL is recorded as the HTTPS URL of the same host, since the Nix
sandbox has no SSH keys. Git submodules are not checked out, as rebar3 does
not check them out.

Plugins, the dependencies of the `test` and `prod` profiles, and the
dependencies of extra profiles added with `--profile` are locked in the same
way.

A few limits apply. A plugin or a build hook that downloads files itself
fails in the sandbox, and C libraries for NIFs and port drivers come from
`buildInputs`. The lock run downloads tarballs from a Hex repository that
needs credentials with your credentials and adds them to the Nix store,
where the build finds them, so another machine needs a `fetchurl` with
credentials in `fetchers`. Your global rebar3 configuration is in effect
during the lock run but not in the sandbox, so the lock run downloads a
plugin that only the global configuration names and the build does not load
it.

`rebar.lock` cannot record everything the build downloads, so the purifier
writes `rebar3-purifier.lock.json` for the rest. `rebar.lock` is the
resolution of the default profile, and it holds the outer checksum of every
Hex package in it, so the lockfile does not repeat them. The lockfile holds
the Hex tarballs that `rebar.lock` does not list (plugins and the other
profiles), the hash and commit object of each git checkout, the outputs of
the build, and the hash of the files that define the dependencies.
`rebar.lock` is an Erlang term, which Nix cannot parse, so Nix reads the
shapes rebar3 writes with regular expressions, and the command reads it
with `file:consult`.

Three more decisions:

- **The package index is generated.** rebar3 reads the Hex registry for
  every Hex dependency before it takes the cached tarball. Registry records
  change with every release, so they cannot be locked by hash. Each Hex
  tarball carries the checksums and requirements the registry holds for its
  version, so the build writes the index rebar3 reads (`hex/packages.idx`,
  format 7) from the locked tarballs, and the etag file beside each.
- **Versions from git are pinned.** An application whose `.app.src` takes
  its version from git (`{vsn, git}`) cannot compute it in the sandbox. The
  lock run records the version, and the build writes it into its copy of the
  `.app.src`.
- **Erlang and rebar3 come from nixpkgs.** The lockfile records the OTP
  release and the rebar3 version of the lock for reference.

## Examples

### erlang_ls

[erlang_ls](https://github.com/erlang-ls/erlang_ls) is a language server
for Erlang, built as an escript. To build it with Nix, clone it, lock it,
and add a flake to the checkout:

```zsh
git clone https://github.com/erlang-ls/erlang_ls
cd erlang_ls
nix run github:nix-purifiers/rebar3-purifier -- lock
```

Create `flake.nix` in the checkout:

```nix
{
  inputs.rebar3-purifier.url = "github:nix-purifiers/rebar3-purifier";
  inputs.nixpkgs.follows = "rebar3-purifier/nixpkgs";

  outputs = { nixpkgs, rebar3-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ rebar3-purifier.overlays.default ];
      };
      project = pkgs.rebar3-purifier.buildRebar3Project { src = ./.; };
    in
    {
      packages.${system}.default = project.packages.escript-erlang_ls;
    };
}
```

Flakes see only the files that git tracks, so add the new files and build:

```zsh
git add flake.nix rebar3-purifier.lock.json
nix build
./result/bin/erlang_ls --version
```

### elvis

[elvis](https://github.com/inaka/elvis) is a style checker for Erlang, also
an escript, with Hex plugins. The steps are the same. Clone it, run the
`lock` command in the checkout, and use the same `flake.nix` with
`project.packages.escript-elvis` in place of `escript-erlang_ls`. The result
is `result/bin/elvis`.

### Your own project

The same steps apply to a project of your own. The package to build is
`project.packages.release-<name>` for a relx release, `escript-<name>` for
an escript, or `app-<name>` for an application, and `project.tests` is the
test run that goes into `checks`.

## Credits

The design follows
[sbt-nix-backend](https://github.com/clhodapp/sbt-nix-backend), the first
of the nix-purifiers: the tool keeps planning the build, a lock run with
empty caches records what the tool downloads, Nix builds from the lockfile,
and the everyday tool reads the same locked downloads. The idea was inspired
by the [cargo (libnix)](https://github.com/nixcloud/cargo) project of
nixcloud. The shared library comes from
[nix-purifiers/purifier](https://github.com/nix-purifiers/purifier).
`docs/development` describes the code for contributors.
rebar3-purifier is released under the MIT license.
