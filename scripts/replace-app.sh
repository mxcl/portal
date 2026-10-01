#!/bin/sh
# Copy and verify before replacing a bundle; never overlay sealed resources.
set -eu
source_app=${1:?source app required}
destination=${2:?destination required}
replacement=$(mktemp -d "$(dirname -- "$destination")/.portal-replace.XXXXXX")
cleanup() {
  if [ -e "$replacement/previous.app" ] && [ ! -e "$destination" ]; then
    mv "$replacement/previous.app" "$destination" || return
  fi
  rm -rf "$replacement"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
/usr/bin/ditto "$source_app" "$replacement/new.app"
/usr/bin/codesign --verify --deep --strict "$replacement/new.app"
if [ -e "$destination" ]; then
  mv "$destination" "$replacement/previous.app"
fi
mv "$replacement/new.app" "$destination"
