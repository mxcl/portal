#!/bin/sh
# Regression: an old profile or removed resource must not survive installation.
set -eu
scripts=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
source_app="$fixture/source.app"
destination="$fixture/installed.app"
mkdir -p "$source_app/Contents/MacOS" "$source_app/Contents/Resources"
cp /usr/bin/true "$source_app/Contents/MacOS/Test"
cat > "$source_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.mxcl.install-test</string>
<key>CFBundleExecutable</key><string>Test</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force --sign - "$source_app"
ditto "$source_app" "$destination"
touch "$destination/Contents/embedded.provisionprofile" "$destination/Contents/Resources/obsolete"
"$scripts/replace-app.sh" "$source_app" "$destination"
test ! -e "$destination/Contents/embedded.provisionprofile"
test ! -e "$destination/Contents/Resources/obsolete"
codesign --verify --deep --strict "$destination"
# A failed signature check must leave the installed bundle intact.
touch "$source_app/Contents/Resources/unsealed"
if "$scripts/replace-app.sh" "$source_app" "$destination"; then
  echo 'Unexpectedly accepted an invalid bundle' >&2
  exit 1
fi
codesign --verify --deep --strict "$destination"
echo 'Bundle replacement regression passed'
