#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Checks that the common mistakes fail with an error that says what to do.
# Each case changes a copy of the hello fixture, builds it with
# buildRebar3Project through nix-build, expects the build to fail, and
# looks for the error. It runs Nix, so it cannot run in the Nix sandbox.
#
# Usage: tests/negative.sh TOOLCHAIN
# where TOOLCHAIN is the output of `nix build .#toolchain`.
set -euo pipefail
if [ -n "${TRACE:-}" ]; then set -x; fi

toolchain=$(cd "${1:?usage: negative.sh TOOLCHAIN}" && pwd)
share="$toolchain/share/rebar3-purifier"
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME="$work/home"
mkdir -p "$HOME"
export PATH="$toolchain/bin:$PATH"

# Builds the project in DIR and expects a failure whose output matches the
# extended regular expression PATTERN.
expect_failure() {
  local name=$1 dir=$2 pattern=$3 cli purifier expr
  cli=$(readlink -f "$share/cli")
  purifier=$(readlink -f "$share/purifier")
  expr="let pkgs = import $share/nixpkgs { }; build = pkgs.callPackage $share/nix-lib/build-rebar3-project.nix { rebar3-purifier.cli = builtins.storePath \"$cli\"; purifier = import (builtins.storePath \"$purifier\" + \"/nix/lib\") { inherit (pkgs) lib; }; }; in (build { src = $dir; }).all"
  if nix-build --no-out-link -E "$expr" > "$work/$name.log" 2>&1; then
    echo "$name: the build succeeded" >&2
    exit 1
  fi
  if ! grep -Eq "$pattern" "$work/$name.log"; then
    echo "$name: the error does not match /$pattern/:" >&2
    tail -20 "$work/$name.log" >&2
    exit 1
  fi
  echo "$name: ok"
}

fixture() {
  cp -r "$here/fixtures/hello" "$work/$1"
  chmod -R u+w "$work/$1"
  rm -rf "$work/$1/_build"
  echo "$work/$1"
}

# A dependency added to rebar.config after the lock: the lockfile is out of
# date.
dir=$(fixture stale)
sed -i 's/{jsx, "3.1.0"}/{jsx, "3.1.0"}, {recon, "2.5.6"}/' "$dir/rebar.config"
expect_failure stale "$dir" 'lockfile is out of date.*rebar3-purifier lock'

# A tarball removed from the lockfile, with the definition files unchanged.
dir=$(fixture missing)
python3 - "$dir/rebar3-purifier.lock.json" <<'EOF'
import json, sys
path = sys.argv[1]
lock = json.load(open(path))
lock["artifacts"] = [a for a in lock["artifacts"] if not a["path"].endswith("/jsx-3.1.0.tar")]
json.dump(lock, open(path, "w"), indent=2)
EOF
expect_failure missing "$dir" 'no download for: jsx 3.1.0.*rebar3-purifier relock'

# A changed hash in the lockfile: the download does not match it.
dir=$(fixture tampered-hash)
python3 - "$dir/rebar3-purifier.lock.json" <<'EOF'
import json, sys
path = sys.argv[1]
lock = json.load(open(path))
for a in lock["artifacts"]:
    if a["path"].endswith("/jsx-3.1.0.tar"):
        a["hash"] = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
json.dump(lock, open(path, "w"), indent=2)
EOF
expect_failure tampered-hash "$dir" 'hash mismatch'

# A changed commit object: the rebuilt repository would not hold the
# locked commit.
dir=$(fixture tampered-commit)
python3 - "$dir/rebar3-purifier.lock.json" <<'EOF'
import base64, json, sys
path = sys.argv[1]
lock = json.load(open(path))
for a in lock["artifacts"]:
    if "git" in a:
        c = a["git"]["commitObject"]
        c["object"] = base64.b64encode(base64.b64decode(c["object"]) + b"tampered\n").decode()
json.dump(lock, open(path, "w"), indent=2)
EOF
expect_failure tampered-commit "$dir" 'purifier: the git entry at path "git/'

# A lockfile that is not JSON.
dir=$(fixture malformed)
echo '{ "version": 1, ' > "$dir/rebar3-purifier.lock.json"
expect_failure malformed "$dir" 'json\.exception\.parse_error'

# A lockfile of another format version.
dir=$(fixture version)
sed -i 's/"version": 1/"version": 0/' "$dir/rebar3-purifier.lock.json"
expect_failure version "$dir" 'lock format version 0.*relock'

# Interactive mode on a lockfile that is not JSON says what to do.
cd "$work/malformed"
if rebar3-purifier env > /dev/null 2> "$work/env.log"; then
  echo "interactive-malformed: rebar3-purifier env succeeded" >&2
  exit 1
fi
grep -q 'is not valid JSON' "$work/env.log"
echo "interactive-malformed: ok"

echo "negative: ok"
