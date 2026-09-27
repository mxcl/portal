#!/bin/sh
set -eu

if [ "$(uname -s)" != Darwin ]; then
  echo "Gitinuum.app can only be installed on macOS." >&2
  exit 1
fi

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
destination=${1:-"/Applications/Gitinuum.app"}
build_dir="$repo_dir/.build/release"
# Keep APNs enabled on ordinary local reinstalls without an environment override.
installed_profile="/Applications/Gitinuum.app/Contents/Library/LoginItems/Gitinuum Menu Helper.app/Contents/embedded.provisionprofile"
push_profile=${GITINUUM_PUSH_PROFILE-}
if [ "${GITINUUM_PUSH_PROFILE+x}" != x ] && [ -f "$installed_profile" ]; then
  push_profile=$installed_profile
fi
signing_identity=${GIT_SYNC_SIGNING_IDENTITY:-"Developer ID Application: Max Howell (ZU76A67LGU)"}
stage=$(mktemp -d "${TMPDIR:-/tmp}/git-sync-install.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM

cd "$repo_dir"
swift build -c release

app="$stage/Gitinuum.app"
menu="$app/Contents/Library/LoginItems/Gitinuum Menu Helper.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" \
  "$menu/Contents/MacOS" "$menu/Contents/Resources" "$(dirname -- "$destination")"
"$repo_dir/scripts/build-terminal-helpers.sh" "$app/Contents"
"$repo_dir/scripts/bundle-terminal-completions.sh" "$app/Contents/Resources"
cp "$build_dir/GitinuumApp" "$app/Contents/MacOS/GitinuumApp"
for resource_bundle in "$build_dir"/*.bundle; do
  cp -R "$resource_bundle" "$app/Contents/Resources/"
done
cp "$build_dir/gitinuumd" "$app/Contents/Resources/gitinuumd"
# Older installed gitinuum launchers still invoke this path.
ln -s gitinuumd "$app/Contents/Resources/git-sync"
cp "$build_dir/gitinuum" "$app/Contents/Resources/gitinuum"
install -m 755 "$repo_dir/app/install-gitinuum.command" "$app/Contents/Resources/install-gitinuum.command"
cp "$build_dir/GitSyncMenuBar" "$menu/Contents/MacOS/GitSyncMenuBar"
cp "$repo_dir/app/Info.plist" "$app/Contents/Info.plist"
cp "$repo_dir/app/MenuInfo.plist" "$menu/Contents/Info.plist"
test "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")" = "dev.mxcl.git-sync"
test "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$menu/Contents/Info.plist")" = "dev.mxcl.git-sync.menu-helper"
if /usr/bin/plutil -extract LSUIElement raw "$app/Contents/Info.plist" >/dev/null 2>&1; then
  echo "The foreground app must not be an LSUIElement." >&2
  exit 1
fi
test "$(/usr/bin/plutil -extract LSUIElement raw "$menu/Contents/Info.plist")" = "true"
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
for icon in AppIcon.icns Assets.car; do
  ln "$app/Contents/Resources/$icon" "$menu/Contents/Resources/$icon"
done

if ! security find-identity -v -p codesigning | grep -Fq "\"$signing_identity\""; then
  echo "Code-signing identity not found: $signing_identity" >&2
  exit 1
fi

codesign --force --sign "$signing_identity" --options runtime --timestamp "$app/Contents/Resources/gitinuumd"
codesign --force --sign "$signing_identity" --options runtime --timestamp "$app/Contents/Resources/gitinuum"
codesign --force --sign "$signing_identity" --options runtime --timestamp "$menu/Contents/MacOS/GitSyncMenuBar"
if [ -n "$push_profile" ]; then
  security cms -D -i "$push_profile" > "$stage/push-profile.plist"
  python3 "$repo_dir/scripts/prepare-push-signing.py" "$stage/push-profile.plist" \
    "$stage/push-entitlements.plist" "$menu/Contents/Info.plist"
  cp "$push_profile" "$menu/Contents/embedded.provisionprofile"
  codesign --force --sign "$signing_identity" --options runtime --timestamp \
    --entitlements "$stage/push-entitlements.plist" "$menu"
else
  codesign --force --sign "$signing_identity" --options runtime --timestamp "$menu"
fi
codesign --force --sign "$signing_identity" --options runtime --timestamp "$app/Contents/MacOS/GitinuumApp"
codesign --force --sign "$signing_identity" --options runtime --timestamp "$app"
if [ -e "$destination" ]; then
  /usr/bin/osascript -e 'tell application id "dev.mxcl.git-sync.menu-helper" to quit' >/dev/null 2>&1 || true
  /usr/bin/osascript -e 'tell application id "dev.mxcl.git-sync" to quit' >/dev/null 2>&1 || true
  sleep 1
  /usr/bin/pkill -x GitSyncMenuBar 2>/dev/null || true
  /usr/bin/pkill -x GitinuumApp 2>/dev/null || true
  /usr/bin/pkill -TERM -f "^$destination/Contents/Resources/(git-sync|gitinuumd) run " 2>/dev/null || true
fi
"$repo_dir/scripts/replace-app.sh" "$app" "$destination"
# Keep the icon files shared even when the copy tool expands hardlinks.
for icon in AppIcon.icns Assets.car; do
  ln -f "$destination/Contents/Resources/$icon" "$destination/Contents/Library/LoginItems/Gitinuum Menu Helper.app/Contents/Resources/$icon"
done
codesign --verify --strict --verbose=2 "$destination/Contents/Library/LoginItems/Gitinuum Menu Helper.app"
codesign --verify --deep --strict --verbose=2 "$destination"

cli_link="$HOME/.local/bin/git-sync"
if [ -L "$cli_link" ] && [ "$(readlink "$cli_link")" = "$destination/Contents/Resources/gitinuumd" ]; then
  rm "$cli_link"
fi

echo "Installed $destination"
