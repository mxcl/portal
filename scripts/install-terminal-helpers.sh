#!/bin/sh
# Run on a Linux SSH host to install the persistent terminal helpers.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$(uname -s)" = Darwin ]; then
  echo 'On macOS, build/install Portal.app to include signed terminal helpers.' >&2
  exit 1
fi
cargo build --manifest-path "$repo_dir/TerminalHelpers/Cargo.toml" --release --locked
output="$HOME/.local/lib/gitinuum/terminal"
mkdir -p "$output"
for helper in gitinuum-sessiond gitinuum-session-bridge; do
  install -m 755 "$repo_dir/TerminalHelpers/target/release/$helper" "$output/.$helper.new"
  mv -f "$output/.$helper.new" "$output/$helper"
done
