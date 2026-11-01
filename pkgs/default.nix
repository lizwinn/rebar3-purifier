# SPDX-License-Identifier: MIT
{ callPackage, ... }:
let
  cli = callPackage ./cli { };
in
{
  # The rebar3-purifier command.
  inherit cli;
  # Erlang and rebar3 with `rebar3` running through rebar3-purifier, and
  # the rebar3-purifier command beside it.
  toolchain = callPackage ./toolchain { inherit cli; };
}
