#!/bin/sh
set -eu

if [ "$(uname -s)" != Darwin ]; then
  echo "Git Sync.app can only be installed on macOS." >&2
  exit 1
fi

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
destination=${1:-"/Applications/Git Sync.app"}
build_dir="$repo_dir/.build/release"
signing_identity=${GIT_SYNC_SIGNING_IDENTITY:-"Developer ID Application: Max Howell (ZU76A67LGU)"}
stage=$(mktemp -d "${TMPDIR:-/tmp}/git-sync-install.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM

cd "$repo_dir"
swift build -c release

app="$stage/Git Sync.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$(dirname -- "$destination")"
cp "$build_dir/GitSync" "$app/Contents/MacOS/GitSync"
cp "$build_dir/git-sync" "$app/Contents/Resources/git-sync"
cp "$repo_dir/app/Info.plist" "$app/Contents/Info.plist"
xcrun actool "$repo_dir/app/AppIcon.icon" \
  --compile "$app/Contents/Resources" \
  --platform macosx \
  --target-device mac \
  --minimum-deployment-target 26.0 \
  --app-icon AppIcon \
  --include-all-app-icons \
  --enable-on-demand-resources NO \
  --output-partial-info-plist "$stage/IconInfo.plist" >/dev/null
test -f "$app/Contents/Resources/Assets.car"
test -f "$app/Contents/Resources/AppIcon.icns"

if ! security find-identity -v -p codesigning | grep -Fq "\"$signing_identity\""; then
  echo "Code-signing identity not found: $signing_identity" >&2
  exit 1
fi

codesign --force --sign "$signing_identity" --options runtime --timestamp "$app/Contents/Resources/git-sync"
codesign --force --sign "$signing_identity" --options runtime --timestamp "$app/Contents/MacOS/GitSync"
codesign --force --sign "$signing_identity" --options runtime --timestamp "$app"
/usr/bin/ditto "$app" "$destination"
codesign --verify --deep --strict --verbose=2 "$destination"

cli_link="$HOME/.local/bin/git-sync"
if [ -L "$cli_link" ] && [ "$(readlink "$cli_link")" = "$destination/Contents/Resources/git-sync" ]; then
  rm "$cli_link"
fi

echo "Installed $destination"
