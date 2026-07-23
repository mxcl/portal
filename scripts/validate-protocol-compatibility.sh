#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_REF="${1:-}"

die() {
  echo "Protocol compatibility check failed: $*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

swift_version() {
  local declaration="$1"
  local property="$2"
  local file="$3"

  awk -v declaration="$declaration" -v property="$property" '
    index($0, declaration) { found_declaration = 1 }
    found_declaration && index($0, "static let " property ": UInt16 =") {
      print $NF
      exit
    }
  ' "$file"
}

rust_version() {
  local property="$1"
  local file="$2"

  awk -v property="$property" '$2 == property ":" { gsub(/;/, "", $5); print $5; exit }' "$file"
}

assert_equal() {
  local label="$1"
  local actual="$2"
  local expected="$3"

  [[ -n "$actual" ]] || die "could not read $label"
  [[ "$actual" == "$expected" ]] || die "$label is $actual; expected $expected"
}

require_fixture() {
  local pattern="$1"
  local file="$2"

  grep -q "$pattern" "$file" || die "$file must retain compatibility fixture $pattern"
}

require_tool cargo
require_tool codex
require_tool git
require_tool swift

session_swift_current="$(swift_version "enum SessionWireProtocol" currentVersion "$ROOT_DIR/src/core/SessionWireProtocol.swift")"
session_swift_previous="$(swift_version "enum SessionWireProtocol" previousVersion "$ROOT_DIR/src/core/SessionWireProtocol.swift")"
session_rust_current="$(rust_version CURRENT_PROTOCOL_VERSION "$ROOT_DIR/src/sessiond/main.rs")"
session_rust_previous="$(rust_version PREVIOUS_PROTOCOL_VERSION "$ROOT_DIR/src/sessiond/main.rs")"
remote_catalog_version="$(swift_version "struct RemoteCatalog" currentVersion "$ROOT_DIR/src/core/RemoteProtocol.swift")"
remote_message_version="$(swift_version "struct RemoteMessage" currentVersion "$ROOT_DIR/src/core/RemoteProtocol.swift")"
relay_envelope_version="$(swift_version "struct RelayCiphertext" currentVersion "$ROOT_DIR/src/core/RelayCrypto.swift")"

assert_equal "Swift and Rust session current versions" "$session_swift_current" "$session_rust_current"
assert_equal "Swift and Rust session previous versions" "$session_swift_previous" "$session_rust_previous"
(( session_swift_previous + 1 == session_swift_current )) ||
  die "session protocol support must be one contiguous current/previous window"
assert_equal "remote catalog and message versions" "$remote_catalog_version" "$remote_message_version"

require_fixture "parse_attach_accepts_expected_wire_shape" "$ROOT_DIR/src/sessiond/main.rs"
require_fixture "parse_attach_v2_tracks_client_role_and_version" "$ROOT_DIR/src/sessiond/main.rs"
require_fixture "session_protocol_capability_parses_daemon_versions" "$ROOT_DIR/src/session_bridge/main.rs"
require_fixture "adjacentVersionNegotiation" "$ROOT_DIR/Tests/VaulttyCoreTests/SessionWireProtocolTests.swift"
require_fixture "unknownMessageKindsDecode" "$ROOT_DIR/Tests/VaulttyCoreTests/RemoteProtocolTests.swift"
require_fixture "previousRelayMessagesDecode" "$ROOT_DIR/Tests/VaulttyCoreTests/RemoteProtocolTests.swift"
require_fixture "terminalSnapshotRoundTrip" "$ROOT_DIR/Tests/VaulttyCoreTests/RemoteProtocolTests.swift"
require_fixture "publishedVector" "$ROOT_DIR/Tests/VaulttyCoreTests/RelayCryptoTests.swift"

echo "Running Rust protocol tests"
cargo test --manifest-path "$ROOT_DIR/Cargo.toml"

echo "Running Swift protocol tests"
swift test --package-path "$ROOT_DIR"

if [[ -z "$BASE_REF" ]]; then
  BASE_REF="$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null || true)"
fi

if [[ -n "$BASE_REF" ]]; then
  git -C "$ROOT_DIR" rev-parse --verify --quiet "$BASE_REF^{commit}" >/dev/null ||
    die "baseline $BASE_REF is not a commit"

  baseline_dir="$(mktemp -d "${TMPDIR:-/tmp}/vaultty-protocol-baseline.XXXXXX")"
  audit_path="$(mktemp "${TMPDIR:-/tmp}/vaultty-protocol-audit.XXXXXX")"
  cleanup() {
    rm -rf "$baseline_dir"
    rm -f "$audit_path"
  }
  trap cleanup EXIT

  for path in \
    src/sessiond/main.rs \
    src/core/SessionWireProtocol.swift \
    src/core/RemoteProtocol.swift \
    src/core/RelayCrypto.swift; do
    git -C "$ROOT_DIR" cat-file -e "$BASE_REF:$path" 2>/dev/null || continue
    mkdir -p "$baseline_dir/$(dirname "$path")"
    git -C "$ROOT_DIR" show "$BASE_REF:$path" >"$baseline_dir/$path"
  done

  baseline_session_version="$(swift_version "enum SessionWireProtocol" currentVersion "$baseline_dir/src/core/SessionWireProtocol.swift")"
  # Releases before explicit negotiation used the unversioned ATTACH wire shape, now v1.
  baseline_session_version="${baseline_session_version:-1}"
  if [[ "$session_swift_current" != "$baseline_session_version" ]]; then
    (( session_swift_current == baseline_session_version + 1 )) ||
      die "session wire version may advance by only one version per release"
    assert_equal "session previous version relative to $BASE_REF" "$session_swift_previous" "$baseline_session_version"
    grep -q "supportedProtocolVersions" "$ROOT_DIR/src/app/PtySession.swift" ||
      die "a session version increase requires client negotiation and fallback"
    assert_equal "Mac session write version during reader-first rollout" \
      "$(swift_version "enum SessionWireProtocol" macWriteVersion "$ROOT_DIR/src/core/SessionWireProtocol.swift")" \
      "$baseline_session_version"
  fi

  "$ROOT_DIR/scripts/test-session-protocol-compatibility.sh" "$BASE_REF"

  if [[ -f "$baseline_dir/src/core/RemoteProtocol.swift" ]]; then
    baseline_catalog_version="$(swift_version "struct RemoteCatalog" currentVersion "$baseline_dir/src/core/RemoteProtocol.swift")"
    baseline_message_version="$(swift_version "struct RemoteMessage" currentVersion "$baseline_dir/src/core/RemoteProtocol.swift")"
    assert_equal "remote catalog version relative to $BASE_REF" "$remote_catalog_version" "$baseline_catalog_version"
    assert_equal "remote message version relative to $BASE_REF" "$remote_message_version" "$baseline_message_version"
  fi

  if [[ -f "$baseline_dir/src/core/RelayCrypto.swift" ]]; then
    baseline_envelope_version="$(swift_version "struct RelayCiphertext" currentVersion "$baseline_dir/src/core/RelayCrypto.swift")"
    assert_equal "relay envelope version relative to $BASE_REF" "$relay_envelope_version" "$baseline_envelope_version"
  fi

  protocol_paths=(
    AGENTS.md
    docs/relay-protocol.md
    src/sessiond/main.rs
    src/session_bridge/main.rs
    src/core/SessionWireProtocol.swift
    src/core/RemoteProtocol.swift
    src/core/RemoteSessionCreationClient.swift
    src/core/RemoteTerminalSessionClient.swift
    src/core/RelayCrypto.swift
    src/app/PtySession.swift
    src/app/main.swift
    src/app/MacRemoteAccessController.swift
    src/app/RelayTerminalSession.swift
    src/ios/MobileRemoteModel.swift
    Tests/VaulttyCoreTests/SessionWireProtocolTests.swift
    Tests/VaulttyCoreTests/RemoteProtocolTests.swift
    Tests/VaulttyCoreTests/RelayCryptoTests.swift
  )

  if ! git -C "$ROOT_DIR" diff --quiet "$BASE_REF..HEAD" -- "${protocol_paths[@]}"; then
    codex exec \
      --cd "$ROOT_DIR" \
      --sandbox read-only \
      --config approval_policy=\"never\" \
      --color never \
      --ephemeral \
      --output-last-message "$audit_path" \
      "Audit Vaultty protocol compatibility for the release diff $BASE_REF..HEAD.

Treat the Protocol compatibility section in AGENTS.md as mandatory. Inspect the diff and relevant tests. Check adjacent-release skew in both directions for the session wire protocol, additive and tolerant relay messages/catalogs, retained relay-envelope readers, daemon upgrade behavior, and SSH helper compatibility. Do not edit files. Perform this focused audit directly; do not invoke skills or delegate to subagents.

The deterministic compatibility fixtures and Rust/Swift test suites have passed. The first output line must be exactly PASS or FAIL. After it, give concise evidence. PASS only if this release preserves every currently applicable requirement and any deferred migration cannot affect peers in this release." \
      >&2 || die "Codex protocol compatibility audit failed to run"

    [[ "$(sed -n '1p' "$audit_path")" == "PASS" ]] || {
      cat "$audit_path" >&2
      die "Codex rejected the protocol compatibility audit"
    }
    cat "$audit_path"
  fi
fi

echo "Protocol compatibility checks passed."
