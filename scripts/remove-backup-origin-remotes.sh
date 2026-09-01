#!/bin/sh
set -eu

usage() {
  echo "Usage: $0 [--apply] BACKUP_DESTINATION" >&2
  exit 64
}

apply=false
if [ "${1:-}" = "--apply" ]; then
  apply=true
  shift
fi
[ "$#" -eq 1 ] || usage

root=$1
[ -d "$root" ] || { echo "Backup destination does not exist: $root" >&2; exit 1; }
root=$(CDPATH='' cd -- "$root" && pwd -P)
case "$root" in
  /|"$HOME") echo "Refusing unsafe destination: $root" >&2; exit 1 ;;
esac

repositories=0
references=0
for repository in "$root"/*.git; do
  [ -d "$repository" ] || continue
  [ "$(git -C "$repository" rev-parse --is-bare-repository 2>/dev/null || true)" = true ] || continue
  deletions=$(git -C "$repository" for-each-ref \
    --format='delete %(refname) %(objectname)' refs/remotes/origin/)
  [ -n "$deletions" ] || continue

  repositories=$((repositories + 1))
  count=$(printf '%s\n' "$deletions" | wc -l | tr -d ' ')
  references=$((references + count))
  echo "${repository#"$root"/}:"
  git -C "$repository" for-each-ref --format='  %(refname)' refs/remotes/origin/

  if [ "$apply" = true ]; then
    {
      echo start
      printf '%s\n' "$deletions"
      echo prepare
      echo commit
    } | git -C "$repository" update-ref --no-deref --stdin >/dev/null
  fi
done

if [ "$apply" = true ]; then
  echo "Removed $references origin refs from $repositories backup repositories."
else
  echo "Would remove $references origin refs from $repositories backup repositories."
  echo "Re-run with --apply to make the changes."
fi
