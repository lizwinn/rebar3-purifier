#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The conformance-offline check: after `rebar3-purifier prefetch`, the
# everyday loop and the editor work without the network. It runs in two
# steps, so that the second runs where the network is cut off, as the
# conformance-offline job of .github/workflows/check.yml does with a
# network namespace of its own.
#
# Usage: tests/offline.sh TOOLCHAIN prefetch DIR
#        tests/offline.sh TOOLCHAIN loop DIR
# where TOOLCHAIN is the output of `nix build .#toolchain`, `prefetch`
# copies the fixtures into DIR and prefetches them, and `loop` runs the
# everyday loop of each fixture in DIR.
set -euo pipefail

toolchain=$(cd "${1:?usage: offline.sh TOOLCHAIN prefetch|loop DIR}" && pwd)
step=${2:?usage: offline.sh TOOLCHAIN prefetch|loop DIR}
dir=${3:?usage: offline.sh TOOLCHAIN prefetch|loop DIR}
here=$(cd "$(dirname "$0")" && pwd)
export PATH="$toolchain/bin:$PATH"

case "$step" in
  prefetch)
    mkdir -p "$dir"
    for fixture in hello umbrella; do
      cp -r "$here/fixtures/$fixture" "$dir/$fixture"
      chmod -R u+w "$dir/$fixture"
      (cd "$dir/$fixture" && rebar3-purifier prefetch)
    done
    ;;
  loop)
    # Every proxy points at an address that refuses connections as well,
    # so a download fails at once wherever the network is not cut off.
    export http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9
    export HTTP_PROXY=$http_proxy HTTPS_PROXY=$https_proxy
    cd "$dir/hello"
    rebar3 compile
    rebar3 eunit
    rebar3 escriptize
    test "$(_build/default/bin/hello Nix)" = '{"hello":"Nix"}'
    elp parse-all --project . --to "$dir/elp"
    test -f "$dir/elp/hello.etf"
    cd "$dir/umbrella"
    rebar3 compile
    rebar3 as prod release
    SERVER_ONESHOT=1 _build/prod/rel/umbrella/bin/umbrella foreground |
      grep -qx 'Hello, Nix (recon 2.5.6, opentelemetry_api 1.5.0)'
    echo "offline: ok"
    ;;
  *)
    echo "unknown step $step" >&2
    exit 2
    ;;
esac
