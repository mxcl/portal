#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_dir"
swift build --product gitinuum
.build/debug/gitinuum --help | grep -q 'Usage: gitinuum'
.build/debug/gitinuum -h | grep -q 'With no arguments, opens Gitinuum'

# A damaged bundle must fail before asking for sudo, including paths with spaces.
stage=$(mktemp -d "${TMPDIR:-/tmp}/gitinuum test.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
cp app/install-gitinuum.command "$stage/"
if /bin/sh "$stage/install-gitinuum.command" >"$stage/output" 2>&1; then
    echo 'Installer unexpectedly accepted a missing executable' >&2
    exit 1
fi
grep -q 'bundled gitinuum executable is missing' "$stage/output"
echo 'gitinuum checks passed'
