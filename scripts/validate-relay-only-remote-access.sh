#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORBIDDEN='SSHHostRecord|StoredSSHHosts|/usr/bin/ssh|runSSH|makeSSH|loadSSHHosts|saveSSHHosts|New Remote Tab|Manage (SSH )?Hosts|vscode-remote://ssh-remote'

if /usr/bin/grep -ERn --include='*.swift' "$FORBIDDEN" \
  "$ROOT_DIR/src/app" "$ROOT_DIR/src/core"; then
  echo "Direct SSH code is forbidden in v1; remote access must use the relay." >&2
  exit 1
fi

if /usr/bin/grep -ERn --include='*.swift' '\.sshHost\(' "$ROOT_DIR/src/app"; then
  echo "The app must not construct legacy direct-SSH session locations." >&2
  exit 1
fi

for binary in "$@"; do
  if strings "$binary" | /usr/bin/grep -Eq "$FORBIDDEN"; then
    echo "Direct SSH capability found in $binary" >&2
    exit 1
  fi
done

echo "Relay-only remote access validation passed."
