# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.rebar3-purifier` (`.cli`, `.toolchain`), and the builder
# `pkgs.buildRebar3Project` (nix/lib/build-rebar3-project.nix) beside them,
# where nixpkgs keeps its own builders, so a package written for
# callPackage takes it by name. Both take the shared purifier library from
# this flake's `purifier` input. A consumer that lists this flake in
# `projects` holds it as `rebar3-purifier/default`, which its package sets
# apply by default.
{ closure-lib, closure-inputs, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "rebar3-purifier";
  # The source of the purifier flake, whose nix/lib the scripts that build
  # outside this flake import.
  purifierSrc = closure-inputs.purifier.outPath;
in
{
  overlay =
    final: prev:
    packages final prev
    // {
      buildRebar3Project = final.callPackage ../../nix/lib/build-rebar3-project.nix {
        purifier = closure-lib.purifier;
      };
      rebar3-purifier = (packages final prev).rebar3-purifier // {
        toolchain = (packages final prev).rebar3-purifier.toolchain.override { inherit purifierSrc; };
      };
    };
}
