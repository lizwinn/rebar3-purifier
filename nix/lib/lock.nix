# SPDX-License-Identifier: MIT
#
# Reads a rebar3-purifier lockfile (written by `rebar3-purifier lock`).
# `lockFile` is a path. The shared purifier library checks the download
# entries when it fetches them.
{ lockFile }:
let
  lock = builtins.addErrorContext "while reading the rebar3-purifier lockfile ${toString lockFile}; if it is not valid JSON, restore it from version control or run `rebar3-purifier relock`" (
    builtins.fromJSON (builtins.readFile lockFile)
  );

  supportedVersion = import ./lock-version.nix;
in
assert
  lock.version == supportedVersion
  || throw "rebar3-purifier: ${toString lockFile} has lock format version ${toString lock.version}; this library reads version ${toString supportedVersion}. Run `rebar3-purifier relock` with the rebar3-purifier revision of this library.";
lock
