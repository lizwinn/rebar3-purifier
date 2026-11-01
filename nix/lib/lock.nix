# SPDX-License-Identifier: MIT
#
# Reads a rebar3-purifier lockfile (written by `rebar3-purifier lock`).
# `lockFile` is a path.
{ lockFile }:
let
  lock = builtins.fromJSON (builtins.readFile lockFile);

  supportedVersion = import ./lock-version.nix;

  # A store path name from a tree path. Store path names allow
  # [A-Za-z0-9+._?=-], must not start with a dot, and are at most 211
  # characters; every other character becomes "_", and a long name keeps
  # its end, where the package name, version and file type are.
  storeName =
    path:
    let
      replaced = builtins.concatStringsSep "" (
        map (part: if builtins.isList part then "_" else part) (builtins.split "[^A-Za-z0-9+._?=-]" path)
      );
      length = builtins.stringLength replaced;
      tail = if length > 200 then builtins.substring (length - 200) 200 replaced else replaced;
      undotted = builtins.head (builtins.match "\\.*(.*)" tail);
    in
    if undotted == "" then "file" else undotted;
in
assert
  lock.version == supportedVersion
  || throw "rebar3-purifier: ${toString lockFile} has lock format version ${toString lock.version}; this library reads version ${toString supportedVersion}. Run `rebar3-purifier relock` with the rebar3-purifier revision of this library.";
lock
// {
  inherit storeName;

  # The fetch name of an entry: the last part of its tree path, made a
  # valid store name.
  artifactName = artifact: storeName (baseNameOf artifact.path);
}
