# SPDX-License-Identifier: MIT
#
# The rebar3-purifier command: the Erlang modules of src/, run on the
# Erlang of the package set with the modules of the rebar3 escript on the
# code path. The build unpacks the rebar3 escript once, compiles the
# modules with erlc, and runs their unit tests.
{
  lib,
  stdenv,
  beamPackages,
  runtimeShell,
}:
let
  inherit (beamPackages) erlang rebar3;
in
stdenv.mkDerivation {
  pname = "rebar3-purifier";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ../../src;
    fileset = ../../src;
  };
  nativeBuildInputs = [ erlang ];

  buildPhase = ''
    runHook preBuild
    mkdir -p ebin rebar3-lib
    erl -noshell -eval '
      {ok, Sections} = escript:extract("${rebar3}/bin/rebar3", []),
      {archive, Archive} = lists:keyfind(archive, 1, Sections),
      {ok, _} = zip:extract(Archive, [{cwd, "rebar3-lib"}]),
      halt().'
    erlc -o ebin *.erl
    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    erl -noshell -pa ebin $(printf ' -pa %s' rebar3-lib/*/ebin) -eval '
      case eunit:test(rp_tests, [verbose]) of
        ok -> halt(0);
        _ -> halt(1)
      end.'
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib" "$out/bin"
    cp -r ebin "$out/lib/rebar3-purifier"
    cp -r rebar3-lib "$out/lib/rebar3"
    {
      echo '#!${runtimeShell}'
      echo "export REBAR3_PURIFIER_CLI=$out/bin/rebar3-purifier"
      # A failure prints its error; it writes no crash dump.
      echo "export ERL_CRASH_DUMP_SECONDS=0"
      printf 'exec %s -noshell' ${erlang}/bin/erl
      printf ' -pa %s' "$out"/lib/rebar3/*/ebin "$out/lib/rebar3-purifier"
      printf " -eval 'rebar3_purifier:main(init:get_plain_arguments())' -extra \"\$@\"\n"
    } > "$out/bin/rebar3-purifier"
    chmod +x "$out/bin/rebar3-purifier"
    runHook postInstall
  '';

  passthru = { inherit erlang rebar3; };
  meta = {
    description = "Nix as the dependency backend of rebar3";
    license = lib.licenses.mit;
    mainProgram = "rebar3-purifier";
  };
}
