#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${1:?usage: test-session-peer-authentication.sh APP_DIR}"
SESSIOND="$APP_DIR/Contents/Helpers/Portal Session Helper.app/Contents/MacOS/gitinuum-sessiond"
BRIDGE="$APP_DIR/Contents/Helpers/gitinuum-session-bridge"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/portal-peer-auth.XXXXXX")"
DAEMON_PID=""
FAKE_PID=""

cleanup() {
  [[ -z "$DAEMON_PID" ]] || kill "$DAEMON_PID" 2>/dev/null || true
  [[ -z "$FAKE_PID" ]] || kill "$FAKE_PID" 2>/dev/null || true
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

wait_for_socket() {
  local socket_path="$1"
  for _ in {1..40}; do
    [[ -S "$socket_path" ]] && return 0
    sleep 0.05
  done
  echo "session authentication test did not create $socket_path" >&2
  return 1
}

SIGNED_SOCKET="$TEST_DIR/signed.sock"
GITINUUM_SESSIOND_SOCKET="$SIGNED_SOCKET" "$SESSIOND" serve >/dev/null 2>&1 &
DAEMON_PID=$!
wait_for_socket "$SIGNED_SOCKET"

response="$(printf 'LIST\n' | \
  GITINUUM_SESSIOND_SOCKET="$SIGNED_SOCKET" \
  GITINUUM_SESSIOND_REQUIRE_EXISTING=1 \
  "$BRIDGE")"
[[ "$response" == "SESSIONS W10=" ]] || {
  echo "signed bridge was rejected by the signed daemon" >&2
  exit 1
}

# Exercise the exact identities of both foreground apps using a signed protocol probe.
for identifier in dev.mxcl.portal dev.mxcl.portal.terminal; do
  probe="$TEST_DIR/$identifier"
  cp "$BRIDGE" "$probe"
  codesign --force --sign "${GIT_SYNC_SIGNING_IDENTITY:-Developer ID Application: Max Howell (ZU76A67LGU)}" \
    --identifier "$identifier" --options runtime --timestamp "$probe"
  response="$(printf 'LIST\n' | GITINUUM_SESSIOND_SOCKET="$SIGNED_SOCKET" \
    GITINUUM_SESSIOND_REQUIRE_EXISTING=1 "$probe")"
  [[ "$response" == "SESSIONS W10=" ]] || { echo "$identifier was rejected" >&2; exit 1; }
done

unsigned_response="$(ruby -rsocket -e '
  socket = UNIXSocket.new(ARGV.fetch(0))
  socket.write("PROTOCOLS\n")
  print socket.read
' "$SIGNED_SOCKET")"
[[ -z "$unsigned_response" ]] || {
  echo "unsigned same-user client received a daemon response" >&2
  exit 1
}

kill "$DAEMON_PID"
wait "$DAEMON_PID" 2>/dev/null || true
DAEMON_PID=""

FAKE_SOCKET="$TEST_DIR/fake.sock"
FAKE_RESULT="$TEST_DIR/fake-result"
ruby -rsocket -e '
  server = UNIXServer.new(ARGV.fetch(0))
  client = server.accept
  puts client.read.bytesize
' "$FAKE_SOCKET" >"$FAKE_RESULT" &
FAKE_PID=$!
wait_for_socket "$FAKE_SOCKET"

if GITINUUM_SESSIOND_SOCKET="$FAKE_SOCKET" \
  GITINUUM_SESSIOND_REQUIRE_EXISTING=1 \
  "$BRIDGE" </dev/null >/dev/null 2>&1; then
  echo "signed bridge accepted an unsigned server" >&2
  exit 1
fi
wait "$FAKE_PID"
FAKE_PID=""
[[ "$(<"$FAKE_RESULT")" == "0" ]] || {
  echo "signed bridge sent protocol bytes before authenticating the server" >&2
  exit 1
}

# Old daemon identities remain trusted during migration, using the original bridge identity.
legacy="$TEST_DIR/legacy-sessiond"
cp "$SESSIOND" "$legacy"
codesign --force --sign "${GIT_SYNC_SIGNING_IDENTITY:-Developer ID Application: Max Howell (ZU76A67LGU)}" \
  --identifier dev.mxcl.git-sync.sessiond --options runtime --timestamp "$legacy"
legacy_socket="$TEST_DIR/legacy.sock"
GITINUUM_SESSIOND_SOCKET="$legacy_socket" "$legacy" serve >/dev/null 2>&1 &
DAEMON_PID=$!
wait_for_socket "$legacy_socket"
response="$(printf 'LIST\n' | GITINUUM_SESSIOND_SOCKET="$legacy_socket" \
  GITINUUM_SESSIOND_REQUIRE_EXISTING=1 "$BRIDGE")"
[[ "$response" == "SESSIONS W10=" ]]
codesign -d --verbose=2 "$BRIDGE" 2>&1 | grep -Fx 'Identifier=dev.mxcl.git-sync.session-bridge'

echo "Session peer authentication checks passed."
