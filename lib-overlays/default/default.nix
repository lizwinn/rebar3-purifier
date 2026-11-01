# SPDX-License-Identifier: MIT
#
# The `rebar3-purifier` library namespace: `readLock`
# (nix/lib/read-lock.nix), which reads the lockfiles of a project into the
# lock in memory of the purifier contract, and the builder
# `buildRebar3Project` (nix/lib/build-rebar3-project.nix), which takes the
# package set to build with as its `pkgs` argument, and fetches with the
# shared purifier library of this library.
{ ... }:
{

  overlay = final: prev: {
    rebar3-purifier = {
      readLock = import ../../nix/lib/read-lock.nix { lib = final; };
      buildRebar3Project = import ../../nix/lib/build-rebar3-project.nix {
        lib = final;
        inherit (final) purifier;
      };
    };
  };

}
