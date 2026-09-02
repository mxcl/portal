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
git -C "$fixture/archive.git" update-ref refs/remotes/pangolin/main "$one"
output=$("$script" --apply --to-host pangolin "$fixture")
case "$output" in *'Refused 1 repositories'*) ;; *) exit 1 ;; esac
test "$(git -C "$fixture/archive.git" show-ref --verify --hash refs/remotes/origin/main)" = "$two"
test "$(git -C "$fixture/archive.git" show-ref --verify --hash refs/remotes/pangolin/main)" = "$one"

echo "origin migration checks passed"
