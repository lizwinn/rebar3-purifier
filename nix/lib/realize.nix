# SPDX-License-Identifier: MIT
#
# The cache tree the rebar3 wrapper builds for interactive use, from the
# nixpkgs and the shared purifier library the toolchain names. `nix-build`
# of this file fetches every entry, and its out link is the GC root that
# keeps them alive.
{
  # The lockfile, as an absolute path.
  lockFile,
  # The rebar3-purifier command, as an absolute path into the store.
  cli,
  # The nixpkgs to fetch with.
  nixpkgs,
  # The source of the shared purifier library.
  purifierSrc,
}:
let
  pkgs = import nixpkgs { };
  match = builtins.match "(${builtins.storeDir}/[^/]+)/bin/rebar3-purifier" cli;
in
assert match != null || throw "rebar3-purifier: the command ${cli} is not in the Nix store";
pkgs.callPackage ./cache.nix {
  inherit lockFile;
  cli = builtins.storePath (builtins.head match);
  purifier = import (builtins.storePath purifierSrc + "/nix/lib") { inherit (pkgs) lib; };
}
