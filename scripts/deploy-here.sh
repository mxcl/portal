#!/usr/bin/env bash
set -euo pipefail

repo="$(git -C "${1:-$PWD}" rev-parse --show-toplevel)"
[[ "$(uname -s)" == Darwin ]] || { echo 'Deploy Here requires macOS.' >&2; exit 1; }
revision="$(git -C "$repo" rev-parse --short=12 HEAD)"
if [[ -n "$(git -C "$repo" status --porcelain)" ]]; then dirty=dirty; else dirty=clean; fi
stage="$(mktemp -d "${TMPDIR:-/tmp}/portal-deploy-here.XXXXXX")"
local_stage="/Applications/.portal-app.install.$revision-$$"
local_backup="/Applications/.portal-app.previous.$revision-$$"
local_terminal="/Applications/.portal-terminal.install.$revision-$$"
terminal_backup="/Applications/.portal-terminal.previous.$revision-$$"
trap 'rm -rf "$stage" "$local_stage" "$local_terminal"' EXIT

"$repo/scripts/install.sh" "$stage/Portal Hub.app"
/usr/bin/codesign --verify --deep --strict "$stage/Portal Hub.app"
/usr/bin/ditto "$stage/Portal Hub.app" "$local_stage"
/usr/bin/ditto "$stage/Portal.app" "$local_terminal"
"$repo/scripts/install-staged.sh" "$local_stage" "$local_backup" "$local_terminal" "$terminal_backup"

for executable in 'Portal Hub.app/Contents/MacOS/PortalApp' 'Portal Hub.app/Contents/Resources/portald' 'Portal Hub.app/Contents/Resources/portal' \
  'Portal Hub.app/Contents/Library/LoginItems/Portal Menu Helper.app/Contents/MacOS/PortalMenuBar' \
  'Portal.app/Contents/MacOS/PortalTerminalApp'; do
  expected_hash="$(shasum -a 256 "$stage/$executable" | awk '{print $1}')"
  installed_hash="$(shasum -a 256 "/Applications/$executable" | awk '{print $1}')"
  [[ "$expected_hash" == "$installed_hash" ]] || {
    echo "Installed executable differs from build: $executable" >&2
    exit 1
  }
done
echo "Deployed Portal $revision ($dirty) to $(scutil --get LocalHostName); app and menu helper restarted and verified."
