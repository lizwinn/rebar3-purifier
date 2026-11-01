#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The conformance-update check: `rebar3-purifier update` on the outdated
# fixture, whose rebar.lock pins jsx 3.0.0, moves jsx to a newer release,
# and rebar.lock and the lockfile then pass the stale check, in the
# command and in readLock. It needs the network and Nix, so it runs in CI
# rather than in the Nix sandbox.
#
# Usage: tests/update.sh TOOLCHAIN
# where TOOLCHAIN is the output of `nix build .#toolchain`.
set -euo pipefail

toolchain=$(cd "${1:?usage: update.sh TOOLCHAIN}" && pwd)
share="$toolchain/share/rebar3-purifier"
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME="$work/home"
mkdir -p "$HOME"
export PATH="$toolchain/bin:$PATH"

cp -r "$here/fixtures/outdated" "$work/outdated"
chmod -R u+w "$work/outdated"
cd "$work/outdated"
grep -q '{pkg,<<"jsx">>,<<"3.0.0">>}' rebar.lock

rebar3-purifier update jsx
if grep -q '{pkg,<<"jsx">>,<<"3.0.0">>}' rebar.lock; then
  echo "update left jsx at 3.0.0" >&2
  exit 1
fi
grep -o '{pkg,<<"jsx">>,<<"[^"]*">>}' rebar.lock

rebar3-purifier check . rebar3-purifier.lock.json
problems=$(nix-instantiate --eval --strict --expr "
  (import $share/nix-lib/read-lock.nix { lib = import $share/nixpkgs/lib; } {
    src = $work/outdated;
  }).problems")
test "$problems" = "[ ]"
echo "update: ok"
