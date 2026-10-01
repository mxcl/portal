#!/bin/sh
set -eu
app=${1:-/Applications/Portal.app}
service="gui/$(id -u)/dev.mxcl.portal.menu-helper"
pid=$(launchctl print "$service" | awk '/^[[:space:]]*pid = / { print $3 }')
test -n "$pid"
/usr/sbin/lsof -a -p "$pid" -d txt -Fn | grep -Fx "n$app/Contents/Library/LoginItems/Portal Menu Helper.app/Contents/MacOS/GitSyncMenuBar"
if launchctl print "gui/$(id -u)/dev.mxcl.git-sync" >/dev/null 2>&1; then
  echo 'The main app is still registered as a startup service' >&2
  exit 1
fi
echo 'Login helper is running from the installed bundle'
