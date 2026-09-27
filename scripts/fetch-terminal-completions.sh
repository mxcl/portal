#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="2.692.3"
SHA256="b07159ef0811bc8cec28e3a3016e6ba9568d774b75b8333dc6a5f2acf7d2c3af"
URL="https://registry.npmjs.org/@withfig/autocomplete/-/autocomplete-${VERSION}.tgz"
VENDOR_DIR="$ROOT_DIR/.build/vendor/fig-autocomplete"
TARBALL="$VENDOR_DIR/autocomplete-${VERSION}.tgz"
PACKAGE_DIR="$VENDOR_DIR/package"

mkdir -p "$VENDOR_DIR"

if [[ ! -f "$TARBALL" ]]; then
  curl -fL "$URL" -o "$TARBALL"
fi

actual_sha256="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
if [[ "$actual_sha256" != "$SHA256" ]]; then
  rm -f "$TARBALL"
  echo "Fig autocomplete checksum mismatch: expected $SHA256, got $actual_sha256" >&2
  exit 1
fi

rm -rf "$PACKAGE_DIR"
tar -xzf "$TARBALL" -C "$VENDOR_DIR" \
  package/build \
  package/package.json \
  package/LICENSE \
  package/README.md

echo "$PACKAGE_DIR"
