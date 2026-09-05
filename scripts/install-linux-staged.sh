#!/usr/bin/env bash
set -euo pipefail

staged_binary="${1:?staged binary required}"
backup_binary="${2:?backup binary required}"
target_binary="$HOME/.local/bin/git-sync"

[[ "$staged_binary" == "$HOME"/.local/bin/.git-sync.install.* ]]
[[ "$backup_binary" == "$HOME"/.local/bin/.git-sync.previous.* ]]
[[ -f "$staged_binary" && ! -e "$backup_binary" ]]

restore() {
  if [[ -f "$backup_binary" ]]; then
    mv -f "$backup_binary" "$target_binary"
  fi
}
trap restore EXIT

chmod 0755 "$staged_binary"
"$staged_binary" help >/dev/null
if [[ -e "$target_binary" ]]; then
  mv "$target_binary" "$backup_binary"
fi
mv "$staged_binary" "$target_binary"
"$target_binary" help >/dev/null

rm -f "$backup_binary"
trap - EXIT
