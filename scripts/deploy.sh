#!/usr/bin/env bash
set -euo pipefail

repo="${1:-$PWD}"
mode="${2:-deploy}"
script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
installer="$script_dir/install-staged.sh"
linux_installer="$script_dir/install-linux-staged.sh"
atlas="atlas"
linux_swift="$HOME/.swiftly/bin/swift"

[[ "$mode" == deploy || "$mode" == --check ]] || {
  echo "Usage: $0 [git-sync-checkout] [--check]" >&2
  exit 64
}

repo="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || {
  echo "Not a Git checkout: $repo" >&2
  exit 1
}
[[ -f "$repo/Package.swift" && -x "$repo/scripts/install.sh" && -f "$repo/app/Info.plist" ]] || {
  echo "Not a git-sync checkout: $repo" >&2
  exit 1
}

local_host="$(scutil --get LocalHostName)"
case "$local_host" in
  maliwan) peer="pangolin" ;;
  pangolin) peer="maliwan" ;;
  *) echo "Deploy Everywhere only supports Maliwan and pangolin; current host is $local_host" >&2; exit 1 ;;
esac

for command in git rsync scp security shasum ssh swift xcrun; do
  command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
done
[[ -x "$installer" ]] || { echo "Installer is not executable: $installer" >&2; exit 1; }
[[ -x "$linux_installer" ]] || { echo "Installer is not executable: $linux_installer" >&2; exit 1; }
[[ -x "$linux_swift" ]] || { echo "Missing open-source Swift toolchain: $linux_swift" >&2; exit 1; }
"$linux_swift" sdk list | grep -Eq '_static-linux-' || {
  echo "Missing aarch64-swift-linux-musl static SDK for $linux_swift" >&2
  exit 1
}

remote_host="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$peer" 'scutil --get LocalHostName')"
[[ "$remote_host" == "$peer" ]] || {
  echo "SSH target $peer identifies as $remote_host" >&2
  exit 1
}
ssh -o BatchMode=yes "$peer" 'command -v codesign >/dev/null && command -v open >/dev/null && command -v shasum >/dev/null'

atlas_platform="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$atlas" 'printf "%s %s" "$(uname -s)" "$(uname -m)"')"
[[ "$atlas_platform" == "Linux aarch64" ]] || {
  echo "SSH target $atlas identifies as $atlas_platform, expected Linux aarch64" >&2
  exit 1
}
atlas_home="$(ssh -o BatchMode=yes "$atlas" 'printf %s "$HOME"')"
[[ "$atlas_home" =~ ^/home/[A-Za-z0-9._-]+$ ]] || {
  echo "Unsafe atlas home path: $atlas_home" >&2
  exit 1
}
ssh -o BatchMode=yes "$atlas" 'command -v sha256sum >/dev/null && test -w "$HOME"'

revision="$(git -C "$repo" rev-parse --short=12 HEAD)"
if [[ -n "$(git -C "$repo" status --porcelain)" ]]; then dirty="dirty"; else dirty="clean"; fi

if [[ "$mode" == --check ]]; then
  echo "Ready to deploy $revision ($dirty) from $local_host to $peer and $atlas."
  exit 0
fi

suffix="$revision-$$"
[[ "$suffix" =~ ^[0-9a-f]+-[0-9]+$ ]]
stage="$(mktemp -d "${TMPDIR:-/tmp}/git-sync-deploy.XXXXXX")"
built_app="$stage/Git Sync.app"
local_stage="/Applications/.git-sync-app.install.$suffix"
local_backup="/Applications/.git-sync-app.previous.$suffix"
remote_stage="/Applications/.git-sync-app.install.$suffix"
remote_backup="/Applications/.git-sync-app.previous.$suffix"
atlas_stage="$atlas_home/.local/bin/.git-sync.install.$suffix"
atlas_backup="$atlas_home/.local/bin/.git-sync.previous.$suffix"

cleanup() {
  rm -rf "$stage"
  [[ "$local_stage" == /Applications/.git-sync-app.install.* ]] && rm -rf "$local_stage"
  ssh -o BatchMode=yes "$peer" "rm -rf '$remote_stage'" 2>/dev/null || true
  ssh -o BatchMode=yes "$atlas" "rm -f '$atlas_stage'" 2>/dev/null || true
}
trap cleanup EXIT

"$repo/scripts/install.sh" "$built_app"
/usr/bin/codesign --verify --deep --strict "$built_app"
"$linux_swift" build --package-path "$repo" -c release --product git-sync --swift-sdk aarch64-swift-linux-musl
linux_binary="$repo/.build/aarch64-swift-linux-musl/release/git-sync"
[[ -x "$linux_binary" ]] || { echo "Linux build missing: $linux_binary" >&2; exit 1; }

ssh -o BatchMode=yes "$peer" "rm -rf '$remote_stage' '$remote_backup'"
rsync -a --delete "$built_app/" "$peer:$remote_stage/"
ssh -o BatchMode=yes "$atlas" "mkdir -p '$atlas_home/.local/bin' && rm -f '$atlas_stage' '$atlas_backup'"
scp -C "$linux_binary" "$atlas:$atlas_stage"
rm -rf "$local_stage" "$local_backup"
/usr/bin/ditto "$built_app" "$local_stage"

"$installer" "$local_stage" "$local_backup"
ssh -o BatchMode=yes "$peer" bash -s -- "$remote_stage" "$remote_backup" < "$installer"
ssh -o BatchMode=yes "$atlas" bash -s -- "$atlas_stage" "$atlas_backup" < "$linux_installer"

local_app_hash="$(shasum -a 256 '/Applications/Git Sync.app/Contents/MacOS/GitSync' | awk '{print $1}')"
local_cli_hash="$(shasum -a 256 '/Applications/Git Sync.app/Contents/Resources/git-sync' | awk '{print $1}')"
remote_app_hash="$(ssh -o BatchMode=yes "$peer" "shasum -a 256 '/Applications/Git Sync.app/Contents/MacOS/GitSync'" | awk '{print $1}')"
remote_cli_hash="$(ssh -o BatchMode=yes "$peer" "shasum -a 256 '/Applications/Git Sync.app/Contents/Resources/git-sync'" | awk '{print $1}')"
linux_hash="$(shasum -a 256 "$linux_binary" | awk '{print $1}')"
atlas_hash="$(ssh -o BatchMode=yes "$atlas" "sha256sum '$atlas_home/.local/bin/git-sync'" | awk '{print $1}')"
[[ "$local_app_hash" == "$remote_app_hash" && "$local_cli_hash" == "$remote_cli_hash" ]] || {
  echo "Installed Git Sync binaries differ between $local_host and $peer" >&2
  exit 1
}
[[ "$linux_hash" == "$atlas_hash" ]] || {
  echo "Installed git-sync binary differs between $local_host and $atlas" >&2
  exit 1
}

trap - EXIT
rm -rf "$stage"
echo "Deployed Git Sync $revision ($dirty) to $local_host, $peer, and $atlas; both apps restarted and the Linux endpoint verified."
