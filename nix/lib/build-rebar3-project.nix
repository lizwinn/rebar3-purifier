# SPDX-License-Identifier: MIT
#
# buildRebar3Project: the sandboxed build of a rebar3 project from the
# lockfile `rebar3-purifier lock` writes next to its rebar.config.
#
# The file is a package for callPackage: the first argument set is what it
# takes from the package set, and the result is the builder. The
# rebar3-purifier overlay (`overlays.default`) adds it to the package set
# as `buildRebar3Project`, so a package written for callPackage takes it
# like any other dependency:
#
#   { buildRebar3Project }: (buildRebar3Project { src = ./.; }).releases.hello
#
# and `buildRebar3Project.override` replaces what it takes from the set.
# The lockfile lists the build's outputs, so every one is an attribute at
# evaluation time. The builder returns
#
#   all                  one derivation with every output: lib/<app>,
#                        releases/<release>, bin/<escript> and
#                        hex/<package>-<version>.tar
#   apps.<name>          each application of the project, compiled: its
#                        ebin, priv and include directories in lib/<name>
#   releases.<name>      each relx release, built with the release profile,
#                        with its start script linked as bin/<name>
#   escripts.<name>      the escript, when rebar.config configures one
#   hexPackages.<name>   each Hex package tarball, when the project uses
#                        rebar3_hex
#   cache                the cache tree of the locked downloads
{
  lib,
  stdenv,
  callPackage,
  runCommand,
  fetchurl,
  fetchgit,
  git,
  beam,
  makeWrapper,
  coreutils,
  gawk,
  gnugrep,
  gnused,
  hostname,
  # The rebar3-purifier package scope, whose `cli` builds the cache tree.
  rebar3-purifier,
  # The shared purifier library (`lib.purifier` of its flake), which
  # fetches the locked downloads. The package overlay passes it.
  purifier,
}:
let
  defaultFetchurl = fetchurl;
  defaultFetchgit = fetchgit;
in
{
  # The project directory, with rebar.config and the lockfile.
  src,
  # The lockfile; the default is the one `rebar3-purifier lock` writes.
  lockFile ? src + "/rebar3-purifier.lock.json",
  # The BEAM package set to build with. The default is the one of the OTP
  # release the lock was made with, when nixpkgs has it.
  beamPackages ? null,
  # The rebar3-purifier command.
  cli ? rebar3-purifier.cli,
  # Replace the fetchers, for credentials or mirrors; the shared purifier
  # library's fetchEntry passes them the arguments of nixpkgs' fetchers.
  fetchurl ? defaultFetchurl,
  fetchgit ? defaultFetchgit,
  # The profile releases are built with.
  releaseProfile ? "prod",
  # Runs `rebar3 eunit`, and `rebar3 ct` when the project has common test
  # suites, after the build.
  doCheck ? false,
  buildInputs ? [ ],
  nativeBuildInputs ? [ ],
  # Filters src before it is copied into the store, as the `filter` of
  # builtins.path. The default leaves out _build, VCS and editor state, and
  # result links.
  srcFilter ? null,
}:
let
  lock = import ./lock.nix { inherit lockFile; };
  inherit (lock) outputs;

  beamSet =
    if beamPackages != null then
      beamPackages
    else
      beam.packages."erlang_${lock.otpRelease}" or beam.packages.erlang;
  inherit (beamSet) erlang rebar3;

  cache = callPackage ./cache.nix {
    inherit
      lockFile
      cli
      fetchurl
      fetchgit
      purifier
      ;
  };

  # git fetches each locked repository from its rebuilt repository in the
  # cache tree. The repositories belong to another user, so git has to
  # trust them.
  gitConfig = [
    {
      key = "safe.directory";
      value = "*";
    }
  ]
  ++ map (s: {
    key = "url.${cache}/${s.path}.insteadOf";
    value = s.url;
  }) lock.gitSources;

  defaultSrcFilter =
    path: type:
    let
      name = baseNameOf path;
    in
    !(name == "_build" || name == ".git" || name == ".idea" || lib.hasPrefix "result" name);

  filteredSrc = builtins.path {
    path = src;
    name = "rebar3-source";
    filter = if srcFilter != null then srcFilter else defaultSrcFilter;
  };

  firstApp = builtins.head outputs.apps;

  all = stdenv.mkDerivation {
    pname = firstApp.name;
    inherit (firstApp) version;
    src = filteredSrc;
    nativeBuildInputs = [
      erlang
      rebar3
      git
      makeWrapper
    ]
    ++ nativeBuildInputs;
    # Escripts and release scripts find escript and erl through these.
    buildInputs = [ erlang ] ++ buildInputs;

    # rebar3 runs with the locked downloads as its cache, a home and global
    # configuration of its own, and Hex's default repository at an address
    # that refuses connections, so it takes every tarball from the cache.
    # The cache is a writable copy, since rebar3 writes into it.
    configurePhase = ''
      runHook preConfigure
      ${cli}/bin/rebar3-purifier check . ${lockFile}
      ${cli}/bin/rebar3-purifier pin-versions . ${lockFile}
      export HOME="$TMPDIR/home"
      export REBAR_GLOBAL_CONFIG_DIR="$TMPDIR/rebar3-global"
      export REBAR_CACHE_DIR="$TMPDIR/rebar3-cache"
      export HEX_CDN=http://127.0.0.1:9
      mkdir -p "$HOME" "$REBAR_GLOBAL_CONFIG_DIR" "$REBAR_CACHE_DIR"
      if [ -d ${cache}/hex ]; then
        cp -rL --no-preserve=mode ${cache}/hex "$REBAR_CACHE_DIR/hex"
      fi
      export GIT_CONFIG_COUNT=${toString (builtins.length gitConfig)}
      ${lib.concatImapStrings (i: c: ''
        export GIT_CONFIG_KEY_${toString (i - 1)}=${lib.escapeShellArg c.key}
        export GIT_CONFIG_VALUE_${toString (i - 1)}=${lib.escapeShellArg c.value}
      '') gitConfig}
      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild
      rebar3 compile
      ${lib.concatMapStrings (r: ''
        rebar3 as ${lib.escapeShellArg releaseProfile} release -n ${lib.escapeShellArg r}
      '') outputs.releases}
      ${lib.optionalString (outputs.escripts != [ ]) "rebar3 escriptize\n"}
      # Each Hex package tarball, without its documentation, which the
      # project's doc provider would build.
      ${lib.concatMapStrings (p: ''
        rebar3 hex build package --app ${lib.escapeShellArg p.name}
      '') outputs.hexPackages}
      runHook postBuild
    '';

    inherit doCheck;
    checkPhase = ''
      runHook preCheck
      rebar3 eunit
      if [ -n "$(find . -path ./_build -prune -o -name '*_SUITE.erl' -print)" ]; then
        rebar3 ct
      fi
      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall
      ${lib.concatMapStrings (a: ''
        mkdir -p "$out/lib/${a.name}"
        for d in ebin priv include; do
          if [ -e "_build/default/lib/${a.name}/$d" ]; then
            cp -rL "_build/default/lib/${a.name}/$d" "$out/lib/${a.name}/"
          fi
        done
      '') outputs.apps}
      ${lib.concatMapStrings (r: ''
        mkdir -p "$out/releases"
        cp -rL ${lib.escapeShellArg "_build/${releaseProfile}/rel/${r}"} "$out/releases/"
        # The relx start script runs these tools from the PATH.
        wrapProgram "$out/releases/${r}/bin/${r}" --prefix PATH : ${
          lib.makeBinPath [
            coreutils
            gawk
            gnugrep
            gnused
            hostname
          ]
        }
      '') outputs.releases}
      ${lib.concatMapStrings (e: ''
        install -Dm755 "_build/default/bin/${e}" "$out/bin/${e}"
      '') outputs.escripts}
      ${lib.concatMapStrings (p: ''
        install -Dm644 "_build/default/lib/${p.name}/hex/${p.name}-${p.version}.tar" \
          "$out/hex/${p.name}-${p.version}.tar"
      '') outputs.hexPackages}
      runHook postInstall
    '';

    passthru = { inherit lock cache; };
    meta.description = "${firstApp.name}, built by rebar3-purifier";
  };

  # One output of the build, as links into `all`, so that every output
  # comes from one build. `links` maps a path in the output to a path in
  # `all`.
  link =
    name: links: extra:
    runCommand name ({ passthru = { inherit all lock cache; }; } // extra) ''
      ${lib.concatStrings (
        lib.mapAttrsToList (to: from: ''
          mkdir -p "$out/$(dirname ${lib.escapeShellArg to})"
          ln -s ${all}/${lib.escapeShellArg from} "$out/"${lib.escapeShellArg to}
        '') links
      )}
    '';

  byName = list: f: lib.listToAttrs (map (x: lib.nameValuePair (x.name or x) (f x)) list);
in
{
  inherit all cache lock;

  apps = byName outputs.apps (
    a: link "${a.name}-${a.version}" { "lib/${a.name}" = "lib/${a.name}"; } { }
  );

  releases = byName outputs.releases (
    r:
    link r {
      "releases/${r}" = "releases/${r}";
      "bin/${r}" = "releases/${r}/bin/${r}";
    } { meta.mainProgram = r; }
  );

  escripts = byName outputs.escripts (
    e: link e { "bin/${e}" = "bin/${e}"; } { meta.mainProgram = e; }
  );

  hexPackages = byName outputs.hexPackages (
    p:
    link "${p.name}-${p.version}" {
      "${p.name}-${p.version}.tar" = "hex/${p.name}-${p.version}.tar";
    } { }
  );
}
