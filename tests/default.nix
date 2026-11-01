# SPDX-License-Identifier: MIT
#
# The flake's checks: builds of the fixtures from their lockfiles, each
# output run or inspected, and the behaviour of the Nix library on its own.
# tests/interactive.sh covers interactive mode and tests/publish.sh the
# upload, which run Nix and so cannot run in the sandbox.
{ pkgs, overlay }:
let
  extended = pkgs.extend overlay;
  inherit (extended) lib runCommand buildRebar3Project;

  # One application with Hex dependencies and plugins, a git dependency in
  # its test profile, an escript, a release and a Hex package.
  hello = buildRebar3Project {
    src = ./fixtures/hello;
    doCheck = true;
  };

  # Two applications under apps/, git dependencies at a tag and in a
  # subdirectory of a repository, a plugin from git, and a release of both.
  umbrella = buildRebar3Project { src = ./fixtures/umbrella; };

  # Runs a command and compares what it prints.
  prints =
    name: command: expected:
    runCommand name { inherit expected; } ''
      ${command} > actual
      printf '%s\n' "$expected" > expected-file
      if ! diff -u expected-file actual; then
        exit 1
      fi
      touch $out
    '';

  lockWithVersion =
    version:
    builtins.toFile "rebar3-purifier.lock.json" (
      builtins.toJSON {
        inherit version;
        artifacts = [ ];
      }
    );
  readsVersion =
    version:
    (builtins.tryEval (import ../nix/lib/lock.nix { lockFile = lockWithVersion version; }).artifacts)
    .success;
in
{
  fixture-hello-escript =
    prints "fixture-hello-escript" "${lib.getExe hello.escripts.hello} Nix"
      ''{"hello":"Nix"}'';

  # The release starts, with the ERTS it includes, prints and stops. The
  # start script prints the command it runs first.
  fixture-hello-release = runCommand "fixture-hello-release" { } ''
    HOME=$TMPDIR HELLO_ONESHOT=1 ${lib.getExe hello.releases.hello} foreground > actual
    grep -qx '{"hello":"release"}' actual
    touch $out
  '';

  # The application's compiled modules, and the Hex package with its
  # metadata.
  fixture-hello-outputs = runCommand "fixture-hello-outputs" { } ''
    test -f ${hello.apps.hello}/lib/hello/ebin/hello.beam
    test -f ${hello.apps.hello}/lib/hello/ebin/hello.app
    tar -xOf ${hello.hexPackages.hello}/hello-0.1.0.tar metadata.config | grep -q '<<"jsx">>'
    touch $out
  '';

  # The cache tree holds every locked tarball with its etag, the package
  # index, and the repository rebuilt from the git checkout, whose tag
  # names the locked commit.
  fixture-hello-cache = runCommand "fixture-hello-cache" { } ''
    for p in cowboy-2.12.0 cowlib-2.13.0 jsx-3.1.0 ranch-1.8.0 erlfmt-1.8.0 rebar3_hex-7.4.0; do
      test -f ${hello.cache}/hex/hexpm/packages/$p.tar
      test -f ${hello.cache}/hex/hexpm/packages/$p.etag
    done
    test -f ${hello.cache}/hex/packages.idx
    repo=${hello.cache}/git/29360b25b708b2dc9d68a4f46f6a1b8b55f72518
    test "$(cat $repo/refs/tags/1.0.0)" = 29360b25b708b2dc9d68a4f46f6a1b8b55f72518
    ${extended.git}/bin/git -c safe.directory='*' -C $repo cat-file -e 29360b25b708b2dc9d68a4f46f6a1b8b55f72518^{tree}
    touch $out
  '';

  fixture-umbrella-release = runCommand "fixture-umbrella-release" { } ''
    HOME=$TMPDIR SERVER_ONESHOT=1 ${lib.getExe umbrella.releases.umbrella} foreground > actual
    grep -qx 'Hello, Nix (recon 2.5.6, opentelemetry_api 1.5.0)' actual
    touch $out
  '';

  # Each application of the umbrella is an output of its own.
  fixture-umbrella-apps = runCommand "fixture-umbrella-apps" { } ''
    test -f ${umbrella.apps.greeter}/lib/greeter/ebin/greeter.beam
    test -f ${umbrella.apps.server}/lib/server/ebin/server_app.beam
    touch $out
  '';

  # The rebar3-purifier command, with its unit tests run in the build, and
  # the toolchain around it.
  inherit (extended.rebar3-purifier) cli toolchain;

  # lock.nix reads the version it supports and rejects any other.
  lock-version =
    assert readsVersion (import ../nix/lib/lock-version.nix);
    assert !(readsVersion 0);
    runCommand "lock-version" { } "touch $out";
}
