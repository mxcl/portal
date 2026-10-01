#!/usr/bin/env bash
set -euo pipefail

staged_binary="${1:?staged binary required}"
backup_binary="${2:?backup binary required}"
target_binary="$HOME/.local/bin/portald"

[[ "$staged_binary" == "$HOME"/.local/bin/.portald.install.* ]]
[[ "$backup_binary" == "$HOME"/.local/bin/.portald.previous.* ]]
[[ -f "$staged_binary" && ! -e "$backup_binary" ]]

restore() {
  if [[ -f "$backup_binary" ]]; then
    mv -f "$backup_binary" "$target_binary"
  fi
}
trap restore EXIT

legacy_state="$HOME/.local/state/git-sync"
portal_state="$HOME/.local/state/portal"
if [[ -d "$legacy_state" && ! -L "$legacy_state" ]]; then
  [[ ! -e "$portal_state" ]] || { echo "Both legacy and Portal state exist" >&2; exit 1; }
  # Refuse to move a live writer's state.
  if pgrep -x 'git-sync|gitinuumd|portald' >/dev/null; then
    echo "Stop the sync daemon before migrating state" >&2; exit 1
  fi
  mv "$legacy_state" "$portal_state"
  ln -s "$portal_state" "$legacy_state"
fi

chmod 0755 "$staged_binary"
"$staged_binary" help >/dev/null
if [[ -e "$target_binary" ]]; then
  mv "$target_binary" "$backup_binary"
fi
mv "$staged_binary" "$target_binary"
"$target_binary" help >/dev/null

# Keep old SSH command paths functional without running an old executable.
for alias in git-sync gitinuumd; do
  cat > "$HOME/.local/bin/$alias" <<'SH'
#!/bin/sh
exec "$(dirname "$0")/portald" "$@"
SH
  chmod 755 "$HOME/.local/bin/$alias"
done
rm -f "$backup_binary"
trap - EXIT
