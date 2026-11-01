# SPDX-License-Identifier: MIT
#
# The cache tree of a lockfile. Hex tarballs are under
# hex/<repository>/packages/, where rebar3 keeps them in its cache
# directory, as links into the store, with the package index and the etags
# beside them. Each git dependency is a bare repository under git/<commit>,
# made from the checkout with the .git directory the shared purifier
# library rebuilds, with the tags and branches rebar3 clones by. The
# rebar3-purifier command is the builder.
{
  lib,
  pkgs,
  runCommand,
  fetchurl,
  fetchgit,
  lockFile,
  # The rebar3-purifier package.
  cli,
  # The shared purifier library (`lib.purifier` of its flake).
  purifier,
}:
let
  lock = import ./lock.nix { inherit lockFile; };
  fetch = purifier.fetchEntry { inherit pkgs fetchurl fetchgit; };
in
runCommand "rebar3-purifier-cache"
  {
    manifest = lib.concatMapStrings (a: "${a.path}\t${fetch a}\n") lock.artifacts;
    passAsFile = [ "manifest" ];
    inherit lockFile;
    passthru = { inherit lock; };
  }
  ''
    ${cli}/bin/rebar3-purifier build-cache
  ''
