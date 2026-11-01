#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Checks `rebar3-purifier publish`, which runs Nix and so cannot run in the
# Nix sandbox. It publishes a copy of the hello fixture to a stand-in Hex
# API on this machine, and checks that the upload is, byte for byte, the
# Hex package Nix built, sent with the API key.
#
# Usage: tests/publish.sh TOOLCHAIN
# where TOOLCHAIN is the output of `nix build .#toolchain`.
set -euo pipefail
if [ -n "${TRACE:-}" ]; then set -x; fi

toolchain=$(cd "${1:?usage: publish.sh TOOLCHAIN}" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'kill "$server" 2>/dev/null || true; rm -rf "$work"' EXIT
export HOME="$work/home"
mkdir -p "$HOME"
export PATH="$toolchain/bin:$PATH"

cp -r "$here/fixtures/hello" "$work/hello"
chmod -R u+w "$work/hello"

# --dry-run builds the package and uploads nothing.
cd "$work/hello"
tarball=$(rebar3-purifier publish --dry-run)
test -f "$tarball"

escript "$here/fake-hex-api.escript" "$work/port" "$work" &
server=$!
for _ in $(seq 1 50); do
  test -s "$work/port" && break
  sleep 0.1
done

HEX_API_KEY=test-key HEX_API_URL="http://127.0.0.1:$(cat "$work/port")/api" \
  rebar3-purifier publish
wait "$server"

cmp "$work/body" "$tarball"
grep -q '^POST /api/packages/hello/releases' "$work/request"
grep -q 'test-key' "$work/request"

echo "publish: ok"
