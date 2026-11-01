# SPDX-License-Identifier: MIT
#
# The fetcher for locked entries. A file entry
# ({ path, url, mirrors, hash }) is a Hex tarball, fetched from its URL and
# then its mirrors. A git entry
# ({ path, git = { url, rev, submodules, leaveDotGit }, hash }) is a clone
# of a repository at one commit, with its .git directory, since rebar3
# clones git dependencies and checks the commit in the clone.
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
    inherit (artifact.git) url rev leaveDotGit;
    inherit (artifact) hash;
    fetchSubmodules = artifact.git.submodules;
  }
else
  fetchurl {
    inherit name;
    urls = [ artifact.url ] ++ artifact.mirrors;
    inherit (artifact) hash;
  }
