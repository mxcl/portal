#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_dir"
swift build --product portal
.build/debug/portal --help | grep -q 'Usage: portal'
.build/debug/portal -h | grep -q 'With no arguments, opens Portal'

# A damaged bundle must fail before asking for sudo, including paths with spaces.
stage=$(mktemp -d "${TMPDIR:-/tmp}/portal test.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
cp app/install-portal.command "$stage/"
if /bin/sh "$stage/install-portal.command" >"$stage/output" 2>&1; then
    echo 'Installer unexpectedly accepted a missing executable' >&2
    exit 1
fi
grep -q 'bundled portal executable is missing' "$stage/output"
echo 'portal checks passed'
