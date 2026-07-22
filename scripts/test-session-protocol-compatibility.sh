#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_REF="${1:?usage: test-session-protocol-compatibility.sh BASE_REF}"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vaultty-session-matrix.XXXXXX")"
PIDS=()

cleanup() {
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

wait_for_socket() {
  local socket_path="$1"
  for _ in {1..40}; do
    [[ -S "$socket_path" ]] && return 0
    sleep 0.05
  done
  echo "session compatibility daemon did not create $socket_path" >&2
  return 1
}

assert_probe() {
  local socket_path="$1"
  local expected="$2"
  ruby -rsocket -e '
    socket = UNIXSocket.new(ARGV.fetch(0))
    socket.write("PROTOCOLS\n")
    response = socket.gets&.strip || "LEGACY_EOF"
    abort "expected #{ARGV.fetch(1)}, got #{response}" unless response == ARGV.fetch(1)
  ' "$socket_path" "$expected"
}

assert_v1_attach() {
  local socket_path="$1"
  local session_id="$2"
  ruby -rbase64 -rsocket -e '
    encoded = ARGV[1, 4].map { |value| Base64.strict_encode64(value) }
    socket = UNIXSocket.new(ARGV.fetch(0))
    socket.write("ATTACH #{encoded.join(" ")}\n")
    response = socket.gets&.strip
    abort "v1 ATTACH failed: #{response.inspect}" unless response&.start_with?("READY ")
  ' "$socket_path" "$session_id" /tmp /usr/bin/false TERM=xterm-256color
}

mkdir -p "$TEMP_DIR/previous"
git -C "$ROOT_DIR" archive "$BASE_REF" | tar -x -C "$TEMP_DIR/previous"

echo "Building released daemon fixture from $BASE_REF"
CARGO_TARGET_DIR="$TEMP_DIR/previous-target" \
  cargo build --quiet --manifest-path "$TEMP_DIR/previous/Cargo.toml" --bin vaultty-sessiond

echo "Building current daemon fixture"
cargo build --quiet --manifest-path "$ROOT_DIR/Cargo.toml" \
  --bin vaultty-sessiond --bin vaultty-session-bridge

previous_socket="$TEMP_DIR/previous.sock"
VAULTTY_SESSIOND_SOCKET="$previous_socket" \
VAULTTY_SESSIOND_DISABLE_PEER_VALIDATION=1 \
  "$TEMP_DIR/previous-target/debug/vaultty-sessiond" serve \
  >"$TEMP_DIR/previous.log" 2>&1 &
PIDS+=("$!")
wait_for_socket "$previous_socket"

echo "Testing current client fallback against previous daemon"
assert_probe "$previous_socket" LEGACY_EOF
assert_v1_attach "$previous_socket" current-client-previous-daemon

current_socket="$TEMP_DIR/current.sock"
VAULTTY_SESSIOND_SOCKET="$current_socket" \
VAULTTY_SESSIOND_DISABLE_PEER_VALIDATION=1 \
  "$ROOT_DIR/target/debug/vaultty-sessiond" serve \
  >"$TEMP_DIR/current.log" 2>&1 &
PIDS+=("$!")
wait_for_socket "$current_socket"

echo "Testing previous v1 client fixture against current daemon"
assert_probe "$current_socket" "PROTOCOLS 1 2"
assert_v1_attach "$current_socket" previous-client-current-daemon

replacement_socket="$TEMP_DIR/replacement.sock"
VAULTTY_SESSIOND_SOCKET="$replacement_socket" \
VAULTTY_SESSIOND_DISABLE_PEER_VALIDATION=1 \
  "$TEMP_DIR/previous-target/debug/vaultty-sessiond" serve \
  >"$TEMP_DIR/replacement.log" 2>&1 &
PIDS+=("$!")
wait_for_socket "$replacement_socket"

echo "Testing safe replacement of an empty previous daemon"
capabilities="$({
  VAULTTY_SESSIOND_SOCKET="$replacement_socket" \
  VAULTTY_SESSIOND="$ROOT_DIR/target/debug/vaultty-sessiond" \
  VAULTTY_SESSIOND_DISABLE_PEER_VALIDATION=1 \
    "$ROOT_DIR/target/debug/vaultty-session-bridge" --capabilities
})"
grep -q '^session-wire=1,2$' <<<"$capabilities"
replacement_pid="$(ruby -rsocket -e '
  socket = UNIXSocket.new(ARGV.fetch(0))
  print socket.getsockopt(0, 2).int
' "$replacement_socket")"
PIDS+=("$replacement_pid")

echo "Session protocol compatibility matrix passed."
