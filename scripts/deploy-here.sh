#!/usr/bin/env bash
set -euo pipefail

repo="$(git -C "${1:-$PWD}" rev-parse --show-toplevel)"
[[ "$(uname -s)" == Darwin ]] || { echo 'Deploy Here requires macOS.' >&2; exit 1; }
revision="$(git -C "$repo" rev-parse --short=12 HEAD)"
if [[ -n "$(git -C "$repo" status --porcelain)" ]]; then dirty=dirty; else dirty=clean; fi
stage="$(mktemp -d "${TMPDIR:-/tmp}/git-sync-deploy-here.XXXXXX")"
local_stage="/Applications/.git-sync-app.install.$revision-$$"
local_backup="/Applications/.git-sync-app.previous.$revision-$$"
trap 'rm -rf "$stage" "$local_stage"' EXIT

"$repo/scripts/install.sh" "$stage/Gitinuum.app"
/usr/bin/codesign --verify --deep --strict "$stage/Gitinuum.app"
/usr/bin/ditto "$stage/Gitinuum.app" "$local_stage"
"$repo/scripts/install-staged.sh" "$local_stage" "$local_backup"

for executable in 'MacOS/GitinuumApp' 'Resources/gitinuumd' 'Resources/gitinuum' \
  'Library/LoginItems/Gitinuum Menu Helper.app/Contents/MacOS/GitSyncMenuBar'; do
  expected_hash="$(shasum -a 256 "$stage/Gitinuum.app/Contents/$executable" | awk '{print $1}')"
  installed_hash="$(shasum -a 256 "/Applications/Gitinuum.app/Contents/$executable" | awk '{print $1}')"
  [[ "$expected_hash" == "$installed_hash" ]] || {
    echo "Installed executable differs from build: $executable" >&2
    exit 1
  }
done
echo "Deployed Gitinuum $revision ($dirty) to $(scutil --get LocalHostName); app and menu helper restarted and verified."
