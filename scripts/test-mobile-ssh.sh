#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
address=${PORTAL_TEST_SSH_ADDRESS:-$(ipconfig getifaddr en0)}
port=${PORTAL_TEST_SSH_PORT:-22993}
directory=$(mktemp -d /tmp/portal-mobile-ssh.XXXXXX)
server_pid=
cleanup() {
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$directory"
}
trap cleanup EXIT
ssh-keygen -q -t ed25519 -N '' -f "$directory/host-key"
cat > "$directory/sshd_config" <<CONFIG
Port $port
ListenAddress $address
HostKey $directory/host-key
PidFile $directory/sshd.pid
AuthorizedKeysFile $directory/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
LogLevel ERROR
CONFIG
/usr/sbin/sshd -D -e -f "$directory/sshd_config" > "$directory/sshd.log" 2>&1 &
server_pid=$!
export PORTAL_TEST_SSH_ADDRESS="$address" PORTAL_TEST_SSH_DIRECTORY="$directory" PORTAL_TEST_SSH_PORT="$port"
if ! swift test --package-path ios; then
    cat "$directory/sshd.log" >&2
    exit 1
fi
