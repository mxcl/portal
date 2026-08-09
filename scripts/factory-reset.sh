#!/bin/sh

set -x

osascript -e 'quit app "Portal"'
killall portal-sessiond 2>/dev/null || true
rm -f "$HOME/Library/Application Support/Portal/sessions.json"
rm -f "$HOME/Library/Application Support/Portal/runtime/sessiond.sock"
