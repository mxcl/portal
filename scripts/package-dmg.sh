#!/bin/sh
# Package the two signed sibling apps produced by install.sh.
set -eu
apps=${1:?Usage: package-dmg.sh /path/to/apps /path/to/output-directory}
output=${2:?output directory required}
identity=${PORTAL_SIGNING_IDENTITY:-${GIT_SYNC_SIGNING_IDENTITY:-"Developer ID Application: Max Howell (ZU76A67LGU)"}}
stage=$(mktemp -d "${TMPDIR:-/tmp}/portal-dmg.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
version=$(plutil -extract CFBundleShortVersionString raw "$apps/Portal Hub.app/Contents/Info.plist")
mkdir -p "$output"
for name in 'Portal Hub' 'Portal'; do
  codesign --verify --deep --strict "$apps/$name.app"
  test "$(plutil -extract CFBundleShortVersionString raw "$apps/$name.app/Contents/Info.plist")" = "$version"
  mkdir "$stage/$name"
  ditto "$apps/$name.app" "$stage/$name/$name.app"
  ln -s /Applications "$stage/$name/Applications"
  dmg="$output/$(echo "$name" | tr ' ' '-')-$version.dmg"
  hdiutil create -volname "$name $version" -srcfolder "$stage/$name" -format UDZO "$dmg"
  codesign --sign "$identity" --timestamp "$dmg"
  codesign --verify --strict "$dmg"
done
