# SPDX-License-Identifier: MIT
#
# The cache tree of a lockfile: every locked entry at its path, as a link
# into the store, with the package index and the etags of the Hex tarballs
# beside them. Hex tarballs are under hex/<repository>/packages/, where
# rebar3 keeps them in its cache directory, and git clones are under
# git/<commit>/. The rebar3-purifier command is the builder.
{
  lib,
  runCommand,
  fetchurl,
  fetchgit,
  lockFile,
  # The rebar3-purifier package.
  cli,
}:
let
  lock = import ./lock.nix { inherit lockFile; };
  fetch = import ./fetch.nix { inherit lock fetchurl fetchgit; };
in
runCommand "rebar3-purifier-cache"
  {
    manifest = lib.concatMapStrings (a: "${a.path}\t${fetch a}\n") lock.artifacts;
    passAsFile = [ "manifest" ];
    passthru = { inherit lock; };
  }
  ''
    ${cli}/bin/rebar3-purifier build-cache
  ''
