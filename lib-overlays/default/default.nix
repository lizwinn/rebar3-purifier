# SPDX-License-Identifier: MIT
#
# The `rebar3-purifier` library namespace: `readLock`
# (nix/lib/read-lock.nix), which reads the lockfiles of a project into the
# lock in memory of the purifier contract.
{ ... }:
{

  overlay = final: prev: {
    rebar3-purifier = {
      readLock = import ../../nix/lib/read-lock.nix { lib = final; };
    };
  };

}
