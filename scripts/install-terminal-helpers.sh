#!/bin/sh
# Run on a Linux SSH host to install the persistent terminal helpers.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$(uname -s)" = Darwin ]; then
  echo 'On macOS, build/install Portal.app to include signed terminal helpers.' >&2
  exit 1
fi
state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
legacy_state="$state_home/gitinuum-terminal"
portal_state="$state_home/portal-terminal"
if [ -d "$legacy_state" ] && [ ! -L "$legacy_state" ]; then
  [ ! -e "$portal_state" ] || { echo 'Both legacy and Portal terminal state exist' >&2; exit 1; }
  if pgrep -x 'gitinuum-sessiond|portal-sessiond' >/dev/null; then
    echo 'Stop the terminal daemon before migrating state' >&2; exit 1
  fi
  mv "$legacy_state" "$portal_state"
  ln -s "$portal_state" "$legacy_state"
fi
cargo build --manifest-path "$repo_dir/TerminalHelpers/Cargo.toml" --release --locked
output="$HOME/.local/lib/portal/terminal"
mkdir -p "$output"
for helper in portal-sessiond portal-session-bridge; do
  install -m 755 "$repo_dir/TerminalHelpers/target/release/$helper" "$output/.$helper.new"
  mv -f "$output/.$helper.new" "$output/$helper"
done

# Older saved SSH configurations still point here; forward to the renamed helpers.
legacy="$HOME/.local/lib/gitinuum/terminal"
mkdir -p "$legacy"
for helper in sessiond session-bridge; do
  cat > "$legacy/gitinuum-$helper" <<SH
#!/bin/sh
exec "\$HOME/.local/lib/portal/terminal/portal-$helper" "\$@"
SH
  chmod 755 "$legacy/gitinuum-$helper"
done
