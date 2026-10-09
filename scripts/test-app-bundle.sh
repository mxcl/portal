#!/bin/sh
set -eu
app=${1:?Usage: test-app-bundle.sh /path/to/Portal.app}
helper="$app/Contents/Library/LoginItems/Portal Menu Helper.app"
test "$(plutil -extract CFBundleName raw "$helper/Contents/Info.plist")" = 'Portal Menu Helper'
test "$(plutil -extract CFBundleIconFile raw "$helper/Contents/Info.plist")" = AppIcon
test "$(plutil -extract LSUIElement raw "$helper/Contents/Info.plist")" = true
for icon in AppIcon.icns Assets.car; do
  test "$app/Contents/Resources/$icon" -ef "$helper/Contents/Resources/$icon"
done
test ! -e "$app/Contents/Library/LoginItems/Gitinuum Menu.app"
test -d "$app/Contents/Resources/CodeEditLanguages_CodeEditLanguages.bundle"
queries="$app/Contents/Resources/CodeEditLanguages_CodeEditLanguages.bundle"
if [ -d "$queries/Contents" ]; then
  queries="$queries/Contents/Resources"
fi
test -f "$queries/Resources/tree-sitter-swift/highlights.scm"
test ! -L "$app/Contents/Resources/git-sync"
"$app/Contents/Resources/portal" --help | grep -q "Usage: portal"
"$app/Contents/Resources/portald" --help | grep -q 'portald daemon'
for alias in git-sync gitinuumd; do
  "$app/Contents/Resources/$alias" --help | grep -q 'portald daemon'
done
"$app/Contents/Resources/gitinuum" --help | grep -q 'Usage: portal'
if [ -f "$helper/Contents/embedded.provisionprofile" ]; then
  entitlements=$(mktemp)
  trap 'rm -f "$entitlements"' EXIT HUP INT TERM
  codesign -d --entitlements :- "$helper" > "$entitlements" 2>/dev/null
  environment=$(python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1], "rb"))["com.apple.developer.aps-environment"])' "$entitlements")
  case "$environment" in development|production) ;; *) exit 1 ;; esac
fi
test -x "$app/Contents/Helpers/portal-session-bridge"
# An upgrade must still authenticate to pre-rename daemons with live shells.
codesign --verify --strict -R '=identifier "dev.mxcl.git-sync.session-bridge"' \
  "$app/Contents/Helpers/portal-session-bridge"
test -x "$app/Contents/Helpers/Portal Session Helper.app/Contents/MacOS/portal-sessiond"
test -d "$app/Contents/Resources/portal_PortalTerminal.bundle"
test -f "$app/Contents/Resources/completions/fig/build/git.js"
codesign --verify --deep --strict "$app"
terminal="$app/Contents/Helpers/Portal Terminal.app"
codesign --verify --strict -R '=identifier "dev.mxcl.git-sync.session-bridge"' \
  "$terminal/Contents/Helpers/portal-session-bridge"
test "$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")" = dev.mxcl.portal
test "$(plutil -extract CFBundleIdentifier raw "$terminal/Contents/Info.plist")" = dev.mxcl.portal.terminal
test "$(plutil -extract CFBundleName raw "$terminal/Contents/Info.plist")" = 'Portal Terminal'
test "$(plutil -extract CFBundleShortVersionString raw "$terminal/Contents/Info.plist")" = "$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
test "$(plutil -extract CFBundleVersion raw "$terminal/Contents/Info.plist")" = "$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")"
test -x "$terminal/Contents/MacOS/PortalTerminalApp"
test -x "$terminal/Contents/Helpers/Portal Session Helper.app/Contents/MacOS/portal-sessiond"
test -f "$terminal/Contents/Resources/completions/fig/build/git.js"
for icon in AppIcon.icns Assets.car; do
  test -s "$terminal/Contents/Resources/$icon"
  if cmp -s "$app/Contents/Resources/$icon" "$terminal/Contents/Resources/$icon"; then
    echo "Portal Terminal must retain its separate terminal icon: $icon" >&2
    exit 1
  fi
done
plutil -extract CFBundleDocumentTypes json -o - "$terminal/Contents/Info.plist" | grep -q com.apple.terminal.shell-script
if plutil -extract CFBundleDocumentTypes json -o - "$app/Contents/Info.plist" >/dev/null 2>&1; then
  echo 'Document handlers belong to Portal Terminal' >&2
  exit 1
fi
for bundle in "$app" "$helper" "$terminal"; do
  cmp "$app/Contents/Resources/session-icon.png" "$bundle/Contents/Resources/session-icon.png"
done
test "$(plutil -extract CFBundleExecutable raw "$app/Contents/Info.plist")" = PortalApp
"$app/Contents/Helpers/portal-session-bridge" --version | grep -q portal-session-bridge
echo 'App bundle checks passed'
