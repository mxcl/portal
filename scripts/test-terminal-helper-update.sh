#!/bin/bash
# A bridge-launched daemon must stay authenticatable after its app is replaced.
set -euo pipefail
app=${1:?usage: test-terminal-helper-update.sh APP}
temp=$(mktemp -d /tmp/terminal-update.XXXXXX)
daemon_pid=''
trap '[[ -z "$daemon_pid" ]] || kill "$daemon_pid" 2>/dev/null || true; rm -rf "$temp"' EXIT
mkdir "$temp/source"
ditto "$app/Contents/Helpers" "$temp/source"
export GITINUUM_SESSIOND_SOCKET="$temp/sessiond.sock"
printf 'PROTOCOLS\n' | "$temp/source/gitinuum-session-bridge" | grep -Fx 'PROTOCOLS 1 2'
daemon_pid=$(/usr/sbin/lsof -t "$GITINUUM_SESSIOND_SOCKET" | head -1)
# Keep a signed client, then simulate replacement of the original bundle.
cp "$temp/source/gitinuum-session-bridge" "$temp/bridge"
rm -rf "$temp/source"
printf 'PROTOCOLS\n' | "$temp/bridge" | grep -Fx 'PROTOCOLS 1 2'
echo 'Terminal helper survives app replacement.'
