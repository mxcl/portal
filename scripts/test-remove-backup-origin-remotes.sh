#!/bin/sh
set -eu

script=$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)/remove-backup-origin-remotes.sh
fixture=$(mktemp -d /tmp/git-sync-origin-migration.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT

git init -q "$fixture/work"
git -C "$fixture/work" config user.name Test
git -C "$fixture/work" config user.email test@example.com
git -C "$fixture/work" commit --allow-empty -qm one
one=$(git -C "$fixture/work" rev-parse HEAD)
git -C "$fixture/work" commit --allow-empty -qm two
two=$(git -C "$fixture/work" rev-parse HEAD)

git init -q --bare "$fixture/archive.git"
git -C "$fixture/archive.git" fetch -q "$fixture/work" "$two"
git -C "$fixture/archive.git" update-ref refs/remotes/origin/main "$two"
git -C "$fixture/archive.git" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

"$script" --to-host pangolin "$fixture" >/dev/null
test "$(git -C "$fixture/archive.git" show-ref --verify --hash refs/remotes/origin/main)" = "$two"

"$script" --apply --to-host pangolin "$fixture" >/dev/null
test "$(git -C "$fixture/archive.git" show-ref --verify --hash refs/remotes/pangolin/main)" = "$two"
test -z "$(git -C "$fixture/archive.git" for-each-ref --format='%(refname)' refs/remotes/origin/)"
test -z "$(git -C "$fixture/archive.git" for-each-ref --format='%(refname)' refs/remotes/pangolin/HEAD)"

git -C "$fixture/archive.git" update-ref refs/remotes/origin/main "$two"
git -C "$fixture/archive.git" update-ref refs/remotes/origin/HEAD "$two"
git -C "$fixture/archive.git" update-ref refs/remotes/pangolin/main "$one"
"$script" --apply --to-host pangolin "$fixture" >/dev/null
test -z "$(git -C "$fixture/archive.git" for-each-ref --format='%(refname)' refs/remotes/origin/)"
test "$(git -C "$fixture/archive.git" show-ref --verify --hash refs/remotes/pangolin/main)" = "$one"
test "$(git -C "$fixture/archive.git" show-ref --verify --hash refs/remotes/pangolin/imported-origin/main)" = "$two"
test -z "$(git -C "$fixture/archive.git" for-each-ref --format='%(refname)' refs/remotes/pangolin/HEAD)"

git -C "$fixture/archive.git" update-ref refs/remotes/origin/main "$two"
git -C "$fixture/archive.git" update-ref refs/remotes/pangolin/imported-origin/main "$one"
if "$script" --apply --to-host pangolin "$fixture" >/dev/null 2>&1; then exit 1; fi
test "$(git -C "$fixture/archive.git" show-ref --verify --hash refs/remotes/origin/main)" = "$two"

echo "origin migration checks passed"
