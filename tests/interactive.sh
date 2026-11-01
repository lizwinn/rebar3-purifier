#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Checks interactive mode, which runs Nix and so cannot run in the Nix
# sandbox. The toolchain's rebar3 builds and tests copies of the fixtures
# from their locked downloads, with every proxy pointing at an address
# that refuses connections, so a download outside the lockfile fails.
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
# profile. The first command fetches the locked downloads through Nix.
cd "$work/hello"
"$toolchain/bin/rebar3-purifier" env > /dev/null
test -L _build/rebar3-purifier/cache-root
offline "$toolchain/bin/rebar3" compile
offline "$toolchain/bin/rebar3" eunit
offline "$toolchain/bin/rebar3" escriptize
test "$(_build/default/bin/hello Nix)" = '{"hello":"Nix"}'

# A changed build definition: the wrapper warns and prints no environment,
# so rebar3 resolves the usual way.
echo '%% changed' >> rebar.config
out=$("$toolchain/bin/rebar3-purifier" env 2>"$work/warning")
test -z "$out"
grep -q 'changed since' "$work/warning"

# REBAR3_PURIFIER=0 turns interactive mode off.
git_free=$(REBAR3_PURIFIER=0 "$toolchain/bin/rebar3-purifier" env)
test -z "$git_free"

# umbrella: git dependencies at a tag and in a subdirectory, and a plugin
# from git, all cloned from the repositories rebuilt in the store.
cd "$work/umbrella"
"$toolchain/bin/rebar3-purifier" env > /dev/null
offline "$toolchain/bin/rebar3" compile
offline "$toolchain/bin/rebar3" as prod release
SERVER_ONESHOT=1 _build/prod/rel/umbrella/bin/umbrella foreground |
  grep -qx 'Hello, Nix (recon 2.5.6, opentelemetry_api 1.5.0)'

echo "interactive mode: ok"
