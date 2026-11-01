# Product

rebar3-purifier makes Nix the dependency backend of rebar3 builds. A
build's downloads are locked by URL or repository and hash, its outputs
build in the Nix sandbox, and interactive rebar3 resolves from the same
locked downloads through the store. The README describes what it does for
a user, including its decisions and limits.

rebar3-purifier is one of the nix-purifiers. Each purifier does the same
for one build tool, and they share the lockfile's download entries: a file
entry is `{ path, url, mirrors, hash }`, and a git entry is
`{ path, git = { url, rev, submodules, leaveDotGit, commitObject }, hash }`,
where `hash` is always of the plain checkout and `commitObject`, when
`leaveDotGit` is true, is `{ object, gitlinks }`. For rebar3, the path of a
file entry is its path in rebar3's cache, and the path of a git entry is
`git/<commit>`, which the rebar3-specific `gitSources` list refers to with
the URL rebar3 uses and the tags and branches it clones by.

## What it owns

- The rebar3-purifier command (`src/`), Erlang modules that run with the
  modules of the rebar3 escript on the code path. `rebar3_purifier` is the
  entry point. `rp_lock` is the lock run and the lockfile format. `rp_index`
  builds the cache tree in Nix and writes the package index and etags from
  the Hex tarballs. `rp_git` reads the commit object and submodule entries
  of each git dependency during the lock run, and makes a bare repository,
  with the tags and branches rebar3 clones by, of the `.git` directory the
  shared purifier library rebuilds. `rp_check` and
  `rp_versions` run in the sandbox before rebar3: the first checks the
  lockfile against the source, the second pins versions that come from
  git. `rp_wrapper` is interactive mode, and `rp_publish` is
  `rebar3-purifier publish`. `rp_util` holds what they share, and
  `rp_tests` the unit tests.
- The Nix library (`nix/lib`). `lock.nix` reads a lockfile and rejects
  other format versions. `cache.nix` is the cache tree, whose entries the
  shared purifier library (the flake's `purifier` input) fetches.
  `realize.nix` builds the tree for interactive mode, and
  `build-rebar3-project.nix` is `buildRebar3Project`.
- The packages (`pkgs`). `cli` is the rebar3-purifier command, with its unit
  tests run in its build. `toolchain` is Erlang and rebar3 with `rebar3`
  replaced by the interactive wrapper, git and nix-prefetch-git at the end
  of its `PATH`, and, under `share/rebar3-purifier`, the nixpkgs, Nix library,
  command and shared purifier library it builds with.

## How the outputs are known

The lock run records the project's applications with their versions, the
relx releases named in `rebar.config`, the escript, and the Hex packages in
the lockfile's `outputs`. `buildRebar3Project` reads them with
`builtins.fromJSON`, so every output is an attribute at evaluation time,
with no import-from-derivation.
