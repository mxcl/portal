#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
resources=${1:?usage: bundle-terminal-completions.sh RESOURCES}
package="$repo_dir/.build/vendor/fig-autocomplete/package"
if [ ! -d "$package/build" ]; then
  "$repo_dir/scripts/fetch-terminal-completions.sh" >/dev/null
fi
mkdir -p "$resources/completions/fig"
cp -R "$package/build" "$resources/completions/fig/"
cp "$package/LICENSE" "$resources/completions/fig/"
cp "$repo_dir/TerminalHelpers/LICENSE" "$resources/Portal-Terminal-LICENSE"
