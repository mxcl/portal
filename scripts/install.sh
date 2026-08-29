#!/bin/sh
set -eu

if [ "$(uname -s)" != Darwin ]; then
  echo "Git Sync.app can only be installed on macOS." >&2
  exit 1
fi

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
destination=${1:-"$HOME/Applications/Git Sync.app"}
build_dir="$repo_dir/.build/release"
stage=$(mktemp -d "${TMPDIR:-/tmp}/git-sync-install.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM

cd "$repo_dir"
swift build -c release --product git-sync --product GitSync

app="$stage/Git Sync.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$(dirname -- "$destination")"
cp "$build_dir/GitSync" "$app/Contents/MacOS/GitSync"
cp "$build_dir/git-sync" "$app/Contents/Resources/git-sync"
cp "$repo_dir/app/Info.plist" "$app/Contents/Info.plist"

codesign --force --sign - --options runtime "$app/Contents/Resources/git-sync"
codesign --force --sign - --options runtime "$app/Contents/MacOS/GitSync"
codesign --force --sign - --options runtime "$app"
/usr/bin/ditto "$app" "$destination"

echo "Installed $destination"
