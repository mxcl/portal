#!/bin/sh
# Package the two signed sibling apps produced by install.sh.
set -eu
apps=${1:?Usage: package-dmg.sh /path/to/apps /path/to/Portal.dmg}
output=${2:?output DMG required}
identity=${PORTAL_SIGNING_IDENTITY:-${GIT_SYNC_SIGNING_IDENTITY:-"Developer ID Application: Max Howell (ZU76A67LGU)"}}
stage=$(mktemp -d "${TMPDIR:-/tmp}/portal-dmg.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
version=$(plutil -extract CFBundleShortVersionString raw "$apps/Portal.app/Contents/Info.plist")
for name in 'Portal.app' 'Portal Terminal.app'; do
  codesign --verify --deep --strict "$apps/$name"
  test "$(plutil -extract CFBundleShortVersionString raw "$apps/$name/Contents/Info.plist")" = "$version"
  ditto "$apps/$name" "$stage/$name"
done
test ! -e "$stage/Portal.app/Contents/Helpers/Portal Terminal.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "Portal $version" -srcfolder "$stage" -format UDZO "$output"
codesign --sign "$identity" --timestamp "$output"
codesign --verify --strict "$output"
