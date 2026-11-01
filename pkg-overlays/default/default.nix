# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.rebar3-purifier` (`.cli`, `.toolchain`). The toolchain takes the
# source of the shared purifier library from this flake's `purifier`
# input. A consumer that lists this flake in `projects` holds it as
# `rebar3-purifier/default`, which its package sets apply by default.
{ closure-inputs, closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "rebar3-purifier";
  # The source of the purifier flake, whose nix/lib the commands that
  # build outside this flake import.
  purifierSrc = closure-inputs.purifier.outPath;
in
{
  overlay =
    final: prev:
    let
      added = packages final prev;
    in
    added
    // {
      rebar3-purifier = added.rebar3-purifier // {
        toolchain = added.rebar3-purifier.toolchain.override { inherit purifierSrc; };
      };
    };
}
