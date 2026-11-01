#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Checks interactive mode and `rebar3-purifier prefetch`, which run Nix and
# so cannot run in the Nix sandbox. The toolchain's rebar3 builds and tests
# copies of the fixtures from their locked downloads, with every proxy
# pointing at an address that refuses connections, so a download outside
# the lockfile fails.
#
# Usage: tests/interactive.sh TOOLCHAIN
# where TOOLCHAIN is the output of `nix build .#toolchain`.
set -euo pipefail

toolchain=$(cd "${1:?usage: interactive.sh TOOLCHAIN}" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME="$work/home"
mkdir -p "$HOME"
# As in `nix develop`: escripts and release scripts find erl and escript.
export PATH="$toolchain/bin:$PATH"

offline() {
  http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 \
    HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 "$@"
}

for fixture in hello umbrella; do
  cp -r "$here/fixtures/$fixture" "$work/$fixture"
  chmod -R u+w "$work/$fixture"
done

# hello: Hex dependencies and plugins, and a git dependency of the test
# profile. prefetch fetches the locked downloads through Nix and keeps
# them and the toolchain alive.
cd "$work/hello"
rebar3-purifier prefetch
test -L .rebar3-purifier-gcroots/cache
test "$(readlink .rebar3-purifier-gcroots/toolchain)" = "$(readlink -f "$toolchain")"
offline rebar3 compile
offline rebar3 eunit
offline rebar3 escriptize
test "$(_build/default/bin/hello Nix)" = '{"hello":"Nix"}'

# The Erlang Language Platform of the toolchain loads the project through
# the same offline rebar3.
offline elp parse-all --project . --to "$work/elp"
test -f "$work/elp/hello.etf"
echo "elp: ok"

# A changed build definition stops rebar3 with the command that fixes it.
echo '%% changed' >> rebar.config
if offline rebar3 compile 2> "$work/error"; then
  echo "rebar3 ran with a stale lockfile" >&2
  exit 1
fi
grep -q 'out of date.*rebar3-purifier lock' "$work/error"

# A malformed lockfile stops rebar3 too.
cp "$here/fixtures/hello/rebar.config" rebar.config
echo '{' > rebar3-purifier.lock.json
if offline rebar3 compile 2> "$work/error"; then
  echo "rebar3 ran with a malformed lockfile" >&2
  exit 1
fi
grep -q 'not valid JSON.*rebar3-purifier lock' "$work/error"

# REBAR3_PURIFIER=0 turns interactive mode off.
test -z "$(REBAR3_PURIFIER=0 rebar3-purifier env)"

# A project without lockfiles, with the lockfile and rebar.lock kept
# outside it: `--lockfile` for the commands, and REBAR3_PURIFIER_LOCKFILE
# for the interactive rebar3.
mkdir -p "$work/external/locks"
cp "$here/fixtures/hello/rebar3-purifier.lock.json" "$here/fixtures/hello/rebar.lock" "$work/external/locks/"
cp -r "$here/fixtures/hello" "$work/external/project"
chmod -R u+w "$work/external"
rm "$work/external/project/rebar3-purifier.lock.json" "$work/external/project/rebar.lock"
cd "$work/external/project"
rebar3-purifier prefetch --lockfile ../locks/rebar3-purifier.lock.json
REBAR3_PURIFIER_LOCKFILE=../locks/rebar3-purifier.lock.json offline rebar3 escriptize
test "$(_build/default/bin/hello Nix)" = '{"hello":"Nix"}'
echo "external lockfile: ok"

# umbrella: git dependencies at a tag and in a subdirectory, and a plugin
# from git, all cloned from the repositories rebuilt in the store.
cd "$work/umbrella"
rebar3-purifier prefetch
offline rebar3 compile
offline rebar3 as prod release
SERVER_ONESHOT=1 _build/prod/rel/umbrella/bin/umbrella foreground |
  grep -qx 'Hello, Nix (recon 2.5.6, opentelemetry_api 1.5.0)'

echo "interactive mode: ok"
