#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORBIDDEN_UI='Manage (SSH )?Hosts|No Remote Hosts Configured|Add Host'
FORBIDDEN_SOURCE='manageSSHHosts|makeSSHHostPanel|saveSSHHosts'

if /usr/bin/grep -q 'DIRECT_SSH_UI' "$ROOT_DIR/scripts/build.sh"; then
  echo "v1 builds must not enable direct SSH UI." >&2
  exit 1
fi

if /usr/bin/grep -ERn --include='*.swift' 'location: \.sshHost' "$ROOT_DIR/src/app"; then
  echo "v1 app code must not create direct SSH sessions." >&2
  exit 1
fi

if /usr/bin/grep -ERn --include='*.swift' "$FORBIDDEN_SOURCE" "$ROOT_DIR/src/app"; then
  echo "v1 app source must not contain direct SSH host management." >&2
  exit 1
fi

if ! /usr/bin/grep -q '"New Remote Tab"' "$ROOT_DIR/src/app/main.swift" ||
  ! /usr/bin/grep -q 'newRelayTab(on:' "$ROOT_DIR/src/app/main.swift"; then
  echo "v1 must expose relay-backed remote tab creation." >&2
  exit 1
fi

for binary in "$@"; do
  if strings "$binary" | /usr/bin/grep -Eq "$FORBIDDEN_UI"; then
    echo "Direct SSH UI found in $binary" >&2
    exit 1
  fi
done

echo "Relay-only entry-point validation passed."
