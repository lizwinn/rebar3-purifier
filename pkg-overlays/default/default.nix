# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds one attribute to the package set,
# the scope `pkgs.rebar3-purifier` that pkgs/ describes, made with
# `lib.makeScope`. The scope holds the command (`.cli`), the toolchain
# (`.toolchain`) and the builder (`.buildRebar3Project`), which share the
# purifier library of this flake (`.purifier`) and its source
# (`.purifierSrc`). `rebar3-purifier.overrideScope` replaces what the
# packages of the scope share. A consumer that lists this flake in
# `projects` holds it as `rebar3-purifier/default`, which its package sets
# apply by default.
{ closure-inputs, closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "rebar3-purifier";
in
{
  overlay =
    final: prev:
    let
      added = packages final prev;
    in
    added
    // {
      rebar3-purifier = added.rebar3-purifier.overrideScope (
        self: super: {
          purifier = closure-lib.purifier;
          purifierSrc = closure-inputs.purifier.outPath;
        }
      );
    };
}
