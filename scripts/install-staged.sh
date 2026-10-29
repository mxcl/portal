#!/usr/bin/env bash
set -euo pipefail

staged_app="${1:?staged app required}"
backup_app="${2:?backup app required}"
target_app="/Applications/Portal Hub.app"

staged_terminal="${3:?staged terminal required}"
backup_terminal="${4:?backup terminal required}"
target_terminal="/Applications/Portal.app"

[[ "$staged_app" == /Applications/.portal-app.install.* ]]
[[ "$backup_app" == /Applications/.portal-app.previous.* ]]
[[ "$staged_terminal" == /Applications/.portal-terminal.install.* ]]
[[ "$backup_terminal" == /Applications/.portal-terminal.previous.* ]]
[[ -d "$staged_app" && ! -e "$backup_app" ]]
[[ -d "$staged_terminal" && ! -e "$backup_terminal" ]]
/usr/bin/codesign --verify --deep --strict "$staged_app"
/usr/bin/codesign --verify --deep --strict "$staged_terminal"

installed_app=false
installed_terminal=false
# shellcheck disable=SC2329 # invoked by the EXIT trap
restore() {
  if $installed_app; then rm -rf "$target_app"; fi
  if $installed_terminal; then rm -rf "$target_terminal"; fi
  if [[ -d "$backup_app" ]]; then mv "$backup_app" "$target_app"; fi
  if [[ -d "$backup_terminal" ]]; then mv "$backup_terminal" "$target_terminal"; fi
}
trap restore EXIT

# Preflight every migration before stopping anything; never merge two state stores.
legacy_paths=("$HOME/Library/Application Support/GitSync" "$HOME/Library/Application Support/Gitinuum/Terminal" "$HOME/.local/state/git-sync" "$HOME/Library/Caches/dev.mxcl.git-sync/project-window-v1.json")
portal_paths=("$HOME/Library/Application Support/Portal/Sync" "$HOME/Library/Application Support/Portal/Terminal" "$HOME/.local/state/portal" "$HOME/Library/Caches/dev.mxcl.portal/project-window-v1.json")
for i in "${!legacy_paths[@]}"; do
  if [[ -e "${legacy_paths[$i]}" && ! -L "${legacy_paths[$i]}" && -e "${portal_paths[$i]}" ]]; then
    echo "Both legacy and Portal state exist: ${portal_paths[$i]}" >&2
    exit 1
  fi
done

# Retired login services can respawn after pkill and compete for the shortcut/engine socket.
for identifier in dev.mxcl.git-sync.menu dev.mxcl.git-sync.menu-helper; do
  service="gui/$(id -u)/$identifier"
  if launchctl print "$service" >/dev/null 2>&1; then
    launchctl disable "$service"
    launchctl bootout "$service" || true
  fi
done

# Login items can appear under their bundle identifier instead of the executable name.
# Preserve both legacy and renamed terminal daemons and their live sessions.
processes='PortalApp|GitinuumApp|PortalTerminalApp|portald|gitinuumd|GitSync|git-sync|GitSyncMenuBar|PortalMenuBar|dev[.]mxcl[.]git-sync[.]menu(-helper)?|dev[.]mxcl[.]portal[.]menu-helper'
pkill -x "$processes" 2>/dev/null || true
for _ in {1..50}; do
  if ! pgrep -x "$processes" >/dev/null; then
    break
  fi
  sleep 0.1
done
pgrep -x "$processes" >/dev/null && pkill -9 -x "$processes"

# Keep old paths as forwarding links for saved configurations and older peers.
for i in "${!legacy_paths[@]}"; do
  old="${legacy_paths[$i]}"; new="${portal_paths[$i]}"
  if [[ -e "$old" && ! -L "$old" ]]; then
    mkdir -p "$(dirname "$new")"
    mv "$old" "$new"
    ln -s "$new" "$old"
  fi
done

# The helper is stopped, so its configuration has a single writer during migration.
/usr/bin/python3 - "$HOME/Library/Application Support/Portal/Sync/config-v2.json" <<'PYCONFIG'
import json, pathlib, shutil, sys
path = pathlib.Path(sys.argv[1])
if path.exists():
    config = json.loads(path.read_text())
    changed = False
    for host in config.get("hosts", []):
        old = host.get("executable", "")
        new = old.replace("/Applications/Portal.app/Contents/Resources/", "/Applications/Portal Hub.app/Contents/Resources/")
        if new.endswith("/.local/bin/gitinuumd") or new.endswith("/.local/bin/git-sync"):
            new = new.rsplit("/", 1)[0] + "/portald"
        if new != old:
            host["executable"] = new
            changed = True
    if changed:
        shutil.copy2(path, str(path) + ".before-hub-rename")
        temporary = path.with_suffix(".migrating")
        temporary.write_text(json.dumps(config, indent=2) + "\n")
        temporary.replace(path)
PYCONFIG

if [[ -d "$target_app" ]]; then
  mv "$target_app" "$backup_app"
fi
mv "$staged_app" "$target_app"
installed_app=true
if [[ -d "$target_terminal" ]]; then
  mv "$target_terminal" "$backup_terminal"
fi
mv "$staged_terminal" "$target_terminal"
installed_terminal=true
/usr/bin/codesign --verify --deep --strict "$target_app"
/usr/bin/codesign --verify --deep --strict "$target_terminal"

cli_link="$HOME/.local/bin/git-sync"
if [[ -L "$cli_link" && "$(readlink "$cli_link")" == "$target_app/Contents/Resources/git-sync" ]]; then
  rm "$cli_link"
fi

rm -rf "$backup_app" "$backup_terminal"
trap - EXIT
# A registered login item can respawn while the old bundle is being replaced.
# Restart it after the swap so it cannot keep running the deleted executable.
menu_service="gui/$(id -u)/dev.mxcl.portal.menu-helper"
if launchctl print "$menu_service" >/dev/null 2>&1; then
  launchctl kickstart -k "$menu_service"
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target_app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target_terminal"
# open forwards its environment to the app (and its terminal sessions).
# Allow only normal login essentials, never the deploying agent's environment.
/usr/bin/env -i HOME="$HOME" USER="$USER" LOGNAME="$LOGNAME" \
  SHELL="${SHELL:-/bin/zsh}" TMPDIR="${TMPDIR:-/tmp}" \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/open "$target_app"

for _ in {1..50}; do
  if pgrep -x PortalApp >/dev/null &&
     /usr/sbin/lsof -t "$target_app/Contents/Library/LoginItems/Portal Menu Helper.app/Contents/MacOS/PortalMenuBar" >/dev/null 2>&1; then
    exit 0
  fi
  sleep 0.1
done
echo "Portal or its installed menu helper did not restart" >&2
exit 1
