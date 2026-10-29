#!/usr/bin/env bash
# Install terminal helpers without stopping existing sessions.
set -euo pipefail
stage=${1:?staged helper directory required}
output="$HOME/.local/lib/portal/terminal"
state="${XDG_STATE_HOME:-$HOME/.local/state}"
for helper in portal-sessiond portal-session-bridge; do
  test -x "$stage/$helper"
  "$stage/$helper" --version >/dev/null
done
# Preserve the pathname of a live legacy daemon's socket and history.
if [[ -d "$state/gitinuum-terminal" && ! -e "$state/portal-terminal" ]]; then
  ln -s "$state/gitinuum-terminal" "$state/portal-terminal"
fi
mkdir -p "$output"
for helper in portal-sessiond portal-session-bridge; do
  install -m 755 "$stage/$helper" "$output/.$helper.new"
  mv -f "$output/.$helper.new" "$output/$helper"
done
"$output/portal-session-bridge" --capabilities
