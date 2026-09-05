#!/usr/bin/env bash
set -euo pipefail

staged_app="${1:?staged app required}"
backup_app="${2:?backup app required}"
target_app="/Applications/Gitinuum.app"

[[ "$staged_app" == /Applications/.git-sync-app.install.* ]]
[[ "$backup_app" == /Applications/.git-sync-app.previous.* ]]
[[ -d "$staged_app" && ! -e "$backup_app" ]]

/usr/bin/codesign --verify --deep --strict "$staged_app"

# shellcheck disable=SC2329 # invoked by the EXIT trap
restore() {
  if [[ -d "$backup_app" && ! -d "$target_app" ]]; then
    mv "$backup_app" "$target_app"
  fi
}
trap restore EXIT

# Login items can appear under their bundle identifier instead of the executable name.
processes='GitinuumApp|gitinuumd|GitSync|git-sync|GitSyncMenuBar|dev[.]mxcl[.]git-sync[.]menu(-helper)?'
pkill -x "$processes" 2>/dev/null || true
for _ in {1..50}; do
  if ! pgrep -x "$processes" >/dev/null; then
    break
  fi
  sleep 0.1
done
pgrep -x "$processes" >/dev/null && pkill -9 -x "$processes"

if [[ -d "$target_app" ]]; then
  mv "$target_app" "$backup_app"
fi
mv "$staged_app" "$target_app"
/usr/bin/codesign --verify --deep --strict "$target_app"

cli_link="$HOME/.local/bin/git-sync"
if [[ -L "$cli_link" && "$(readlink "$cli_link")" == "$target_app/Contents/Resources/git-sync" ]]; then
  rm "$cli_link"
fi

rm -rf "$backup_app"
trap - EXIT
# A registered login item can respawn while the old bundle is being replaced.
# Restart it after the swap so it cannot keep running the deleted executable.
menu_service="gui/$(id -u)/dev.mxcl.git-sync.menu-helper"
if launchctl print "$menu_service" >/dev/null 2>&1; then
  launchctl kickstart -k "$menu_service"
fi
open "$target_app"

for _ in {1..50}; do
  if pgrep -x GitinuumApp >/dev/null &&
     /usr/sbin/lsof -t "$target_app/Contents/Library/LoginItems/Gitinuum Menu Helper.app/Contents/MacOS/GitSyncMenuBar" >/dev/null 2>&1; then
    exit 0
  fi
  sleep 0.1
done
echo "Gitinuum or its installed menu helper did not restart" >&2
exit 1
