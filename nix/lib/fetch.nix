# SPDX-License-Identifier: MIT
#
# The fetcher for locked entries. A file entry
# ({ path, url, mirrors, hash }) is a Hex tarball, fetched from its URL and
# then its mirrors. A git entry
# ({ path, git = { url, rev, submodules, leaveDotGit, commitObject }, hash })
# is a plain checkout of a repository at one commit, which `hash` pins.
# A checkout with its .git directory has no stable hash, so the fetch never
# keeps .git; with `leaveDotGit`, the cache tree rebuilds it from the
# checkout and `commitObject` (see src/rp_git.erl).
#
# `fetchurl` and `fetchgit` are nixpkgs' fetchers or replacements for them,
# such as fetchers with credentials or mirrors. A file's store path depends
# only on its name and hash, so a tarball that `rebar3-purifier lock` added
# to the store is found without a download.
{
  lock,
  fetchurl,
  fetchgit,
}:
artifact:
let
  name = lock.artifactName artifact;
in
if artifact ? git then
  fetchgit {
    inherit name;
    inherit (artifact.git) url rev;
    inherit (artifact) hash;
    fetchSubmodules = artifact.git.submodules;
  }
else
  fetchurl {
    inherit name;
    urls = [ artifact.url ] ++ artifact.mirrors;
    inherit (artifact) hash;
  }
