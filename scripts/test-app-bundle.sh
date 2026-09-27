#!/bin/sh
set -eu
app=${1:?Usage: test-app-bundle.sh /path/to/Gitinuum.app}
helper="$app/Contents/Library/LoginItems/Gitinuum Menu Helper.app"
test "$(plutil -extract CFBundleName raw "$helper/Contents/Info.plist")" = 'Gitinuum Menu Helper'
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
test "$(readlink "$app/Contents/Resources/git-sync")" = gitinuumd
"$app/Contents/Resources/gitinuumd" --help | grep -q 'gitinuumd daemon'
"$app/Contents/Resources/git-sync" --help | grep -q 'gitinuumd daemon'
if [ -f "$helper/Contents/embedded.provisionprofile" ]; then
  entitlements=$(mktemp)
  trap 'rm -f "$entitlements"' EXIT HUP INT TERM
  codesign -d --entitlements :- "$helper" > "$entitlements" 2>/dev/null
  environment=$(python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1], "rb"))["com.apple.developer.aps-environment"])' "$entitlements")
  case "$environment" in development|production) ;; *) exit 1 ;; esac
fi
test -x "$app/Contents/Helpers/gitinuum-session-bridge"
test -x "$app/Contents/Helpers/Gitinuum Session Helper.app/Contents/MacOS/gitinuum-sessiond"
test -d "$app/Contents/Resources/git-sync_PortalTerminal.bundle"
test -f "$app/Contents/Resources/completions/fig/build/git.js"
codesign --verify --deep --strict "$app"
echo 'App bundle checks passed'
