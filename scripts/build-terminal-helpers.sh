#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
contents=${1:?usage: build-terminal-helpers.sh APP_CONTENTS}
identity=${GIT_SYNC_SIGNING_IDENTITY:-"Developer ID Application: Max Howell (ZU76A67LGU)"}
cargo build --manifest-path "$repo_dir/TerminalHelpers/Cargo.toml" --release --locked
helpers="$contents/Helpers"
helper_app="$helpers/Portal Session Helper.app"
mkdir -p "$helper_app/Contents/MacOS"
cp "$repo_dir/TerminalHelpers/target/release/gitinuum-sessiond" "$helper_app/Contents/MacOS/"
cp "$repo_dir/TerminalHelpers/target/release/gitinuum-session-bridge" "$helpers/"
cat > "$helper_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.mxcl.portal.sessiond</string>
<key>CFBundleExecutable</key><string>gitinuum-sessiond</string>
<key>CFBundleName</key><string>Portal Session Helper</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSBackgroundOnly</key><true/>
<key>LSMinimumSystemVersion</key><string>26.0</string>
</dict></plist>
PLIST
codesign --force --sign "$identity" --options runtime --timestamp "$helper_app"
codesign --force --sign "$identity" --options runtime --timestamp \
  --identifier dev.mxcl.portal.session-bridge "$helpers/gitinuum-session-bridge"
codesign --verify --strict "$helper_app"
codesign --verify --strict "$helpers/gitinuum-session-bridge"
