# Product

rebar3-purifier makes Nix the dependency backend of rebar3 builds. A
build's downloads are locked by URL or repository and hash, its outputs
build in the Nix sandbox, and interactive rebar3 resolves from the same
locked downloads through the store. The README describes what it does for
a user, including its decisions and limits.

rebar3-purifier is one of the nix-purifiers. Each purifier does the same
for one build tool, and they meet the purifier contract (CONTRACT.md in
the shared library). They share the download entries of the library: a
file entry is `{ path, url, mirrors, hash }`, and a git entry is
`{ path, git = { url, rev, submodules, leaveDotGit, commitObject }, hash }`,
where `hash` is always of the plain checkout and `commitObject`, when
`leaveDotGit` is true, is `{ object, gitlinks }`. For rebar3, the path of a
file entry is its path in the cache of rebar3, and the path of a git entry
is `git/<commit>`. A git entry carries `rebar3Sources`, the URLs rebar3
clones the checkout from, with the tags and branches it clones by.

## What it owns

- The rebar3-purifier command (`src/`), Erlang modules that run with the
  modules of the rebar3 escript on the code path. `rebar3_purifier` is the
  entry point and dispatches `lock`, `update`, `prefetch` and `publish`,
  and the commands the toolchain and the Nix build use. `rp_lock` is the
  lock run and the lockfile format. `rp_index` builds the cache tree in Nix
  and writes the package index and etags from the Hex tarballs. `rp_git`
  reads the commit object and submodule entries of each git dependency
  during the lock run, and makes a bare repository, with the tags and
  branches rebar3 clones by, of the `.git` directory the shared purifier
  library rebuilds. `rp_check` checks a lockfile against its project in
  the sandbox before rebar3, in interactive mode, in `prefetch` and in
  `publish`. `rp_versions` pins versions that come from git. `rp_wrapper`
  is interactive mode and `prefetch`, and `rp_publish` is
  `rebar3-purifier publish`. `rp_util` holds what they share, including
  the lockfile with its content hash, the project and its `--lockfile`, and
  the readers of `rebar.lock`. `rp_tests` holds the unit tests.
- The Nix library (`nix/lib`). `read-lock.nix` is `readLock`, which reads
  the lockfile and `rebar.lock` into the lock in memory of the contract,
  with the problems of a lockfile that cannot be used. `content-hash.nix`
  and `lock-version.nix` are the content hash and the format version, which
  the command computes the same way. `cache.nix` is the cache tree, whose
  entries the shared purifier library fetches. `realize.nix` builds the
  tree for interactive mode and `prefetch`, and `build-rebar3-project.nix`
  is `buildRebar3Project`.
- The packages (`pkgs`). `cli` is the rebar3-purifier command, with its unit
  tests run in its build. `toolchain` is Erlang and rebar3 with `rebar3`
  replaced by the interactive wrapper, `elp`, git and nix-prefetch-git at
  the end of its `PATH`, and, under `share/rebar3-purifier`, the nixpkgs,
  Nix library, command and shared purifier library it builds with.

## The lockfile

`rebar3-purifier.lock.json` holds what `rebar.lock` cannot supply: the Hex
tarballs that `rebar.lock` does not list (plugins and the dependencies of
the other profiles, and packages from repositories other than hexpm), the
hash, URL, commit object and clone sources of each git checkout, the
outputs of the build, the hash of the files that define the dependencies,
the profiles, the OTP release, the format version and a content hash of the
lockfile itself. `readLock` derives the entry of every Hex package in
`rebar.lock` from its outer checksum, the SHA-256 of the tarball.

## How the outputs are known

The lock run records the applications of the project with their versions,
the relx releases named in `rebar.config`, the escript, and the Hex
packages in the `outputs` field of the lockfile. `readLock` names them
`app-<name>`, `release-<name>`, `escript-<name>` and `hex-<name>`, and
`buildRebar3Project` builds an attribute for each, so every output is
known at evaluation time, with no import-from-derivation.
