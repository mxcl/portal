#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URL="https://automicvault.com/db.json"
OUTPUT="$ROOT_DIR/src/app/command-descriptions.json"

tmp="$(mktemp "${TMPDIR:-/tmp}/portal-db.XXXXXX.json")"
trap 'rm -f "$tmp"' EXIT

curl -L --fail --silent --show-error "$URL" -o "$tmp"

python3 - "$tmp" "$OUTPUT" <<'PY'
import json
import os
import sys

source_path, output_path = sys.argv[1:]
with open(source_path, "r", encoding="utf-8") as f:
    db = json.load(f)["sources"]["db"]

descriptions = {}
for command, package in db["entries"].items():
    if package.startswith("cask:"):
        summary = db["casks"].get(package[5:], {}).get("summary")
    elif package.startswith("npm:"):
        summary = db["npms"].get(package[4:], {}).get("summary")
    else:
        summary = db["formulas"].get(package, {}).get("summary")
    if summary:
        descriptions[command] = summary

os.makedirs(os.path.dirname(output_path), exist_ok=True)
with open(output_path, "w", encoding="utf-8") as f:
    json.dump(descriptions, f, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
    f.write("\n")

assert descriptions["git"] == "Distributed revision control system"
assert descriptions["op"] == "Command-line interface for 1Password"
print(f"Wrote {len(descriptions)} command descriptions to {output_path}")
PY
