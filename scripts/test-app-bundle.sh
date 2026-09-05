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
test "$(readlink "$app/Contents/Resources/git-sync")" = gitinuumd
"$app/Contents/Resources/gitinuumd" --help | grep -q 'gitinuumd daemon'
"$app/Contents/Resources/git-sync" --help | grep -q 'gitinuumd daemon'
codesign --verify --deep --strict "$app"
echo 'App bundle checks passed'
