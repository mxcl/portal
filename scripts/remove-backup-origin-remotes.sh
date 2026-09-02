#!/bin/sh
set -eu

usage() {
  echo "Usage: $0 [--apply] [--to-host HOST] BACKUP_DESTINATION" >&2
  exit 64
}

apply=false
host=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) apply=true ;;
    --to-host)
      shift
      [ "$#" -gt 0 ] || usage
      host=$1
      ;;
    --) shift; break ;;
    -*) usage ;;
    *) break ;;
  esac
  shift
done
[ "$#" -eq 1 ] || usage
if [ -n "$host" ]; then
  case "$host" in
    origin|''|*[!a-z0-9-]*|-*|*-) usage ;;
  esac
fi

root=$1
[ -d "$root" ] || { echo "Backup destination does not exist: $root" >&2; exit 1; }
root=$(CDPATH='' cd -- "$root" && pwd -P)
case "$root" in
  /|"$HOME") echo "Refusing unsafe destination: $root" >&2; exit 1 ;;
esac

repositories=0
references=0
refused=0
for repository in "$root"/*.git; do
  [ -d "$repository" ] || continue
  [ "$(git -C "$repository" rev-parse --is-bare-repository 2>/dev/null || true)" = true ] || continue
  deletions=$(git -C "$repository" for-each-ref \
    --format='delete %(refname) %(objectname)' refs/remotes/origin/)
  [ -n "$deletions" ] || continue

  echo "${repository#"$root"/}:"
  git -C "$repository" for-each-ref --format='  %(refname)' refs/remotes/origin/

  if [ -n "$host" ]; then
    updates=$deletions
    mappings=
    collisions=
    refs=$(git -C "$repository" for-each-ref \
      --format='%(refname) %(objectname) %(symref)' refs/remotes/origin/)
    while read -r ref oid symref; do
      [ -n "$ref" ] || continue
      suffix=${ref#refs/remotes/origin/}
      [ -n "$symref" ] && continue
      if [ "$suffix" = HEAD ]; then
        if git -C "$repository" rev-list --exclude="$ref" --all | grep -Fqx "$oid"; then
          continue
        fi
        target="refs/remotes/$host/imported-origin/HEAD"
      else
        target="refs/remotes/$host/$suffix"
      fi
      target_oid=$(git -C "$repository" show-ref --verify --hash "$target" 2>/dev/null || true)
      if [ "$suffix" != HEAD ] && [ -n "$target_oid" ] && [ "$target_oid" != "$oid" ]; then
        target="refs/remotes/$host/imported-origin/$suffix"
        target_oid=$(git -C "$repository" show-ref --verify --hash "$target" 2>/dev/null || true)
      fi
      if [ -n "$target_oid" ] && [ "$target_oid" != "$oid" ]; then
        collisions="$collisions
  $ref -> $target"
      elif [ -z "$target_oid" ]; then
        updates="create $target $oid
$updates"
      fi
      mappings="$mappings
  $ref -> $target"
    done <<EOF
$refs
EOF

    if [ -n "$collisions" ]; then
      refused=$((refused + 1))
      echo "  Refusing: destination refs already point elsewhere:$collisions"
      continue
    fi

    printf '%s\n' "$mappings"
    repositories=$((repositories + 1))
    count=$(printf '%s\n' "$deletions" | wc -l | tr -d ' ')
    references=$((references + count))
    if [ "$apply" = true ]; then
      {
        echo start
        printf '%s\n' "$updates"
        echo prepare
        echo commit
      } | git -C "$repository" update-ref --no-deref --stdin >/dev/null
    fi
    continue
  fi

  reachable=$(git -C "$repository" rev-list --exclude='refs/remotes/origin/*' --all)
  unsafe=$(git -C "$repository" for-each-ref \
    --format='%(refname) %(objectname)' refs/remotes/origin/ | while read -r ref oid; do
      printf '%s\n' "$reachable" | grep -Fqx "$oid" || echo "  $ref"
    done)
  if [ -n "$unsafe" ]; then
    refused=$((refused + 1))
    echo "  Refusing: these refs contain commits not reachable from retained refs:"
    printf '%s\n' "$unsafe"
    continue
  fi

  repositories=$((repositories + 1))
  count=$(printf '%s\n' "$deletions" | wc -l | tr -d ' ')
  references=$((references + count))

  if [ "$apply" = true ]; then
    {
      echo start
      printf '%s\n' "$deletions"
      echo prepare
      echo commit
    } | git -C "$repository" update-ref --no-deref --stdin >/dev/null
  fi
done

if [ -n "$host" ] && [ "$apply" = true ]; then
  echo "Migrated $references origin refs to $host in $repositories backup repositories."
elif [ -n "$host" ]; then
  echo "Would migrate $references origin refs to $host in $repositories backup repositories."
  echo "Re-run with --apply to make the changes."
elif [ "$apply" = true ]; then
  echo "Removed $references origin refs from $repositories backup repositories."
else
  echo "Would remove $references origin refs from $repositories backup repositories."
  echo "Re-run with --apply to make the changes."
fi
if [ "$refused" -ne 0 ]; then
  echo "Refused $refused repositories; no changes were made to them."
  exit 1
fi
