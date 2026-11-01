# SPDX-License-Identifier: MIT
#
# The `rebar3-purifier` library namespace. It holds nothing: the builder
# needs a package set, so it is the package `buildRebar3Project` that the
# default package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    rebar3-purifier = prev.rebar3-purifier or { };
  };

}
