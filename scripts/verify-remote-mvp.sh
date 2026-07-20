#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"

cd "$ROOT_DIR"
cargo test
swift test
swift build \
  --triple arm64-apple-ios26.1-simulator \
  --sdk "$IOS_SDK" \
  --target VaulttyMobile

echo "Remote MVP protocol, cryptography, relay fan-out, and Apple client builds passed."
