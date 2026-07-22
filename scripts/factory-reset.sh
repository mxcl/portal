#!/bin/sh

set -x

osascript -e 'quit app "InfiniTTY"'
killall vaultty-sessiond 2>/dev/null || true
rm -f "$HOME/Library/Application Support/Vaultty/sessions.json"
rm -f "$HOME/Library/Application Support/Vaultty/runtime/sessiond.sock"
