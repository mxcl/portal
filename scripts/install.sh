#!/bin/sh
set -eu

if [ "$(uname -s)" != Darwin ]; then
  echo "Portal Hub.app can only be installed on macOS." >&2
  exit 1
fi

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
destination=${1:-"/Applications/Portal Hub.app"}
terminal_destination="$(dirname -- "$destination")/Portal.app"
build_dir="$repo_dir/.build/release"
# Keep APNs enabled on ordinary local reinstalls without an environment override.
installed_profile="/Applications/Portal Hub.app/Contents/Library/LoginItems/Portal Menu Helper.app/Contents/embedded.provisionprofile"
push_profile=${PORTAL_PUSH_PROFILE-${GITINUUM_PUSH_PROFILE-}}
if [ "${PORTAL_PUSH_PROFILE+x}" != x ] && [ "${GITINUUM_PUSH_PROFILE+x}" != x ] && [ -f "$installed_profile" ]; then
  push_profile=$installed_profile
fi
signing_identity=${PORTAL_SIGNING_IDENTITY:-${GIT_SYNC_SIGNING_IDENTITY:-"Developer ID Application: Max Howell (ZU76A67LGU)"}}
stage=$(mktemp -d "${TMPDIR:-/tmp}/portal-install.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM

cd "$repo_dir"
swift build -c release

app="$stage/Portal Hub.app"
terminal="$stage/Portal.app"
menu="$app/Contents/Library/LoginItems/Portal Menu Helper.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" \
  "$menu/Contents/MacOS" "$menu/Contents/Resources" "$(dirname -- "$destination")"
"$repo_dir/scripts/build-terminal-helpers.sh" "$app/Contents"
cat > "$app/Contents/Resources/legacy-terminal-bridge" <<'SH'
#!/bin/sh
exec "$(dirname "$0")/../Helpers/portal-session-bridge" "$@"
SH
chmod 755 "$app/Contents/Resources/legacy-terminal-bridge"
ln -s ../Resources/legacy-terminal-bridge "$app/Contents/Helpers/gitinuum-session-bridge"
"$repo_dir/scripts/bundle-terminal-completions.sh" "$app/Contents/Resources"
cp "$build_dir/PortalApp" "$app/Contents/MacOS/PortalApp"
for resource_bundle in "$build_dir"/*.bundle; do
  case "$(basename "$resource_bundle")" in git-sync_*|CodeEdit*) continue ;; esac
  cp -R "$resource_bundle" "$app/Contents/Resources/"
done
cp "$build_dir/portald" "$app/Contents/Resources/portald"
cp "$build_dir/portal" "$app/Contents/Resources/portal"
# Old peer configurations can still request the old paths; exec the newly named binaries.
for alias in git-sync gitinuumd; do
  cat > "$app/Contents/Resources/$alias" <<'SH'
#!/bin/sh
exec "$(dirname "$0")/portald" "$@"
SH
  chmod 755 "$app/Contents/Resources/$alias"
done
cat > "$app/Contents/Resources/gitinuum" <<'SH'
#!/bin/sh
exec "$(dirname "$0")/portal" "$@"
SH
chmod 755 "$app/Contents/Resources/gitinuum"
cp "$repo_dir/app/session-icon.png" "$app/Contents/Resources/session-icon.png"
cp "$repo_dir/app/session-icon.png" "$menu/Contents/Resources/session-icon.png"
install -m 755 "$repo_dir/app/install-portal.command" "$app/Contents/Resources/install-portal.command"
cp "$build_dir/PortalMenuBar" "$menu/Contents/MacOS/PortalMenuBar"
cp "$repo_dir/app/Info.plist" "$app/Contents/Info.plist"
cp "$repo_dir/app/MenuInfo.plist" "$menu/Contents/Info.plist"
test "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")" = "dev.mxcl.portal"
test "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$menu/Contents/Info.plist")" = "dev.mxcl.portal.menu-helper"
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

mkdir -p "$terminal/Contents/MacOS" "$terminal/Contents/Resources"
cp "$build_dir/PortalTerminalApp" "$terminal/Contents/MacOS/"
cp "$repo_dir/app/TerminalInfo.plist" "$terminal/Contents/Info.plist"
mkdir -p "$terminal/Contents/Helpers"
cp -R "$app/Contents/Helpers/Portal Session Helper.app" "$terminal/Contents/Helpers/"
cp "$app/Contents/Helpers/portal-session-bridge" "$terminal/Contents/Helpers/"
cp -R "$app/Contents/Resources/portal_PortalTerminal.bundle" "$terminal/Contents/Resources/"
cp -R "$app/Contents/Resources/completions" "$terminal/Contents/Resources/"
cp "$repo_dir/app/session-icon.png" "$terminal/Contents/Resources/session-icon.png"
xcrun actool "$repo_dir/app/terminal/AppIcon.icon" \
  --compile "$terminal/Contents/Resources" \
  --platform macosx \
  --target-device mac \
  --minimum-deployment-target 26.0 \
  --app-icon AppIcon \
  --include-all-app-icons \
  --enable-on-demand-resources NO \
  --output-partial-info-plist "$stage/TerminalIconInfo.plist" >/dev/null
codesign --force --sign "$signing_identity" --options runtime --timestamp "$terminal"

if ! security find-identity -v -p codesigning | grep -Fq "\"$signing_identity\""; then
  echo "Code-signing identity not found: $signing_identity" >&2
  exit 1
fi

codesign --force --sign "$signing_identity" --options runtime --timestamp "$app/Contents/Resources/portald"
codesign --force --sign "$signing_identity" --options runtime --timestamp "$app/Contents/Resources/portal"
codesign --force --sign "$signing_identity" --options runtime --timestamp "$menu/Contents/MacOS/PortalMenuBar"
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
codesign --force --sign "$signing_identity" --options runtime --timestamp "$app/Contents/MacOS/PortalApp"
discovery_profile=${PORTAL_DISCOVERY_PROFILE:-"$HOME/Library/MobileDevice/Provisioning Profiles/Portal_Developer_ID.provisionprofile"}
if [ ! -f "$discovery_profile" ]; then
  discovery_profile="/Applications/Portal Hub.app/Contents/embedded.provisionprofile"
fi
security cms -D -i "$discovery_profile" > "$stage/discovery-profile.plist"
python3 "$repo_dir/scripts/prepare-discovery-signing.py" "$stage/discovery-profile.plist" "$stage/discovery-entitlements.plist"
cp "$discovery_profile" "$app/Contents/embedded.provisionprofile"
codesign --force --sign "$signing_identity" --options runtime --timestamp \
  --entitlements "$stage/discovery-entitlements.plist" "$app"
if [ -e "$destination" ]; then
  /usr/bin/osascript -e 'tell application id "dev.mxcl.portal.menu-helper" to quit' >/dev/null 2>&1 || true
  /usr/bin/osascript -e 'tell application id "dev.mxcl.portal" to quit' >/dev/null 2>&1 || true
  sleep 1
  /usr/bin/pkill -x PortalMenuBar 2>/dev/null || true
  /usr/bin/pkill -x PortalApp 2>/dev/null || true
  /usr/bin/pkill -TERM -f "^$destination/Contents/Resources/(git-sync|portald) run " 2>/dev/null || true
fi
"$repo_dir/scripts/replace-app.sh" "$terminal" "$terminal_destination"
"$repo_dir/scripts/replace-app.sh" "$app" "$destination"
# Keep the icon files shared even when the copy tool expands hardlinks.
for icon in AppIcon.icns Assets.car; do
  ln -f "$destination/Contents/Resources/$icon" "$destination/Contents/Library/LoginItems/Portal Menu Helper.app/Contents/Resources/$icon"
done
codesign --verify --strict --verbose=2 "$destination/Contents/Library/LoginItems/Portal Menu Helper.app"
codesign --verify --deep --strict --verbose=2 "$destination"

cli_link="$HOME/.local/bin/git-sync"
if [ -L "$cli_link" ] && [ "$(readlink "$cli_link")" = "$destination/Contents/Resources/portald" ]; then
  rm "$cli_link"
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$destination"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$terminal_destination"
echo "Installed $destination"
