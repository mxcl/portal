#!/bin/sh
set -eu
app=${1:-/Applications/Portal Hub.app}
service="gui/$(id -u)/dev.mxcl.portal.menu-helper"
registration=$(launchctl print "$service")
pid=$(printf '%s\n' "$registration" | awk '/^[[:space:]]*pid = / { print $3 }')
test -n "$pid"
# A stale pre-rename registration can survive even when the helper is opened directly.
registered_version=$(printf '%s\n' "$registration" | awk '/parent bundle version = / { print $5 }')
installed_version=$(/usr/bin/plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")
test "$registered_version" = "$installed_version"
/usr/sbin/lsof -a -p "$pid" -d txt -Fn | grep -Fx "n$app/Contents/Library/LoginItems/Portal Menu Helper.app/Contents/MacOS/PortalMenuBar"
if launchctl print "gui/$(id -u)/dev.mxcl.git-sync" >/dev/null 2>&1; then
  echo 'The main app is still registered as a startup service' >&2
  exit 1
fi
echo 'Login helper is running from the installed bundle'
