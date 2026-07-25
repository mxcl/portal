#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="Portal"
EXECUTABLE_NAME="Vaultty"
APP_BUNDLE_ID="com.automicvault.vaultty"
SESSIOND_HELPER_ID="com.automicvault.vaultty.sessiond"
SESSION_BRIDGE_ID="com.automicvault.vaultty.session-bridge"
REMOTE_AGENT_ID="com.automicvault.vaultty.remote-agent"
APP_KEYCHAIN_ACCESS_GROUP="ZU76A67LGU.$APP_BUNDLE_ID"
GHOSTTY_PROBE_ID="com.automicvault.vaultty.ghostty-probe"
MIN_MACOS_VERSION="26.1"
FIG_AUTOCOMPLETE_DIR="$ROOT_DIR/target/vendor/fig-autocomplete/package"
COMMAND_DESCRIPTIONS_FILE="$ROOT_DIR/src/app/command-descriptions.json"
WITH_GHOSTTY_VT=false
RUN_APP=false
INSTALL_APP=false
CREATE_DMG=false
NOTARIZE_DMG=false
PUBLISH_RELEASE=false
CLOBBER_RELEASE=false
OUTPUT_PATH=""
APP_ARGS=()
ORIGINAL_ARGS=("$@")

usage() {
  cat <<'EOF'
Usage: scripts/build.sh [--debug|--release] [--install] [--run] [--dmg] [--notarize] [--publish] [--clobber] [--with-ghostty-vt] [--output PATH] [-- APP_ARGS...]

Build and codesign Portal.app using an installed Developer ID identity.

Options:
  --install          Replace /Applications/Portal.app with the built app.
  --run              Open the built app, or exec it when APP_ARGS are supplied.
  --dmg              Build a DMG.
  --notarize         Build and notarize a DMG.
  --publish          Plan, build, notarize, and publish a GitHub release.
  --clobber          Replace the existing release for the current Cargo version.
  --output PATH      Write the DMG to PATH.
  --with-ghostty-vt  Require target/ghostty-vt and bundle a libghostty-vt probe.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)
      CONFIGURATION=debug
      shift
      ;;
    --release)
      CONFIGURATION=release
      shift
      ;;
    --with-ghostty-vt)
      WITH_GHOSTTY_VT=true
      shift
      ;;
    --install)
      INSTALL_APP=true
      shift
      ;;
    --run)
      RUN_APP=true
      shift
      ;;
    --dmg)
      CREATE_DMG=true
      shift
      ;;
    --notarize)
      CREATE_DMG=true
      NOTARIZE_DMG=true
      shift
      ;;
    --publish)
      CREATE_DMG=true
      NOTARIZE_DMG=true
      PUBLISH_RELEASE=true
      shift
      ;;
    --clobber)
      CLOBBER_RELEASE=true
      shift
      ;;
    --output)
      [[ $# -ge 2 ]] || { echo "--output requires a path" >&2; exit 1; }
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      APP_ARGS=("$@")
      break
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$CLOBBER_RELEASE" == true && "$PUBLISH_RELEASE" != true ]]; then
  echo "--clobber requires --publish" >&2
  exit 1
fi

if [[ "$NOTARIZE_DMG" == true &&
  ( -z "${APPLE_PASSWORD:-}" || -z "${APPLE_USERNAME:-}" ) &&
  -x /usr/local/bin/av &&
  -z "${VAULTTY_AV_INJECTED:-}" ]]; then
  export VAULTTY_AV_INJECTED=1
  exec /usr/local/bin/av inject +APPLE_PASSWORD +APPLE_USERNAME /bin/bash "$0" "${ORIGINAL_ARGS[@]}"
fi

BUILD_DIR="$ROOT_DIR/target/app/$CONFIGURATION"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
EXECUTABLE="$MACOS_DIR/$EXECUTABLE_NAME"
SESSIOND_HELPER="$HELPERS_DIR/vaultty-sessiond"
SESSION_BRIDGE_HELPER="$HELPERS_DIR/vaultty-session-bridge"
GHOSTTY_PROBE="$HELPERS_DIR/portal-ghostty-probe"
GHOSTTY_DYLIB="$FRAMEWORKS_DIR/libghostty-vt.dylib"
GHOSTTY_BRIDGE_OBJECT="$BUILD_DIR/GhosttyOscBridge.o"
ICON_BUNDLE="$ROOT_DIR/assets/AppIcon.icon"
ICON_SOURCE="$ICON_BUNDLE/Assets/Vaultty.png"
ICONSET_DIR="$BUILD_DIR/$APP_NAME.iconset"
COMMAND_DESCRIPTIONS_FILE="$ROOT_DIR/src/app/command-descriptions.json"
SWIFT_DEPS_BUILD_PATH="$ROOT_DIR/target/swift-deps/$CONFIGURATION"

unquote_env_value() {
  local value="$1"
  case "$value" in
    \"*\")
      value="${value#\"}"
      value="${value%\"}"
      ;;
    \'*\')
      value="${value#\'}"
      value="${value%\'}"
      ;;
  esac
  printf '%s' "$value"
}

die() {
  echo "$*" >&2
  exit 1
}

normalize_profile_path() {
  local path="$1"
  path="$(unquote_env_value "$path")"
  if [[ "$path" == \~/* ]]; then
    path="$HOME/${path#~/}"
  fi
  printf '%s' "$path"
}

decode_provisioning_profile() {
  local profile_path="$1"
  local output_path="$2"

  if /usr/bin/security cms -D -i "$profile_path" >"$output_path" 2>/dev/null; then
    return 0
  fi

  if command -v openssl >/dev/null 2>&1 &&
      openssl smime \
        -inform DER \
        -verify \
        -noverify \
        -in "$profile_path" \
        -out "$output_path" \
        >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

profile_plist_value() {
  local plist_path="$1"
  local key_path="$2"
  /usr/libexec/PlistBuddy -c "Print $key_path" "$plist_path" 2>/dev/null || true
}

profile_matches_main_app() {
  local profile_path="$1"
  local decoded_path app_identifier team_identifier keychain_groups

  decoded_path="$(mktemp "${TMPDIR:-/tmp}/vaultty-profile.XXXXXX")"
  if ! decode_provisioning_profile "$profile_path" "$decoded_path"; then
    rm -f "$decoded_path"
    return 1
  fi

  app_identifier="$(profile_plist_value "$decoded_path" ":Entitlements:com.apple.application-identifier")"
  team_identifier="$(profile_plist_value "$decoded_path" ":Entitlements:com.apple.developer.team-identifier")"
  keychain_groups="$(profile_plist_value "$decoded_path" ":Entitlements:keychain-access-groups")"
  rm -f "$decoded_path"

  [[ "$app_identifier" == "$APP_KEYCHAIN_ACCESS_GROUP" ]] || return 1
  [[ "$keychain_groups" == *"$APP_KEYCHAIN_ACCESS_GROUP"* ||
     "$keychain_groups" == *"${team_identifier}.*"* ]]
}

find_main_app_provisioning_profile() {
  local search_dir profile
  for search_dir in \
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
    "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    [[ -d "$search_dir" ]] || continue
    while IFS= read -r profile; do
      if profile_matches_main_app "$profile"; then
        printf '%s\n' "$profile"
        return 0
      fi
    done < <(find "$search_dir" -type f \( -name '*.provisionprofile' -o -name '*.mobileprovision' \) 2>/dev/null | sort)
  done
  return 1
}

resolve_main_app_provisioning_profile() {
  local profile="${VAULTTY_PROVISIONING_PROFILE:-}"
  if [[ -n "$profile" ]]; then
    profile="$(normalize_profile_path "$profile")"
    [[ -f "$profile" ]] || die "Portal provisioning profile not found: $profile"
    profile_matches_main_app "$profile" ||
      die "Portal provisioning profile does not authorize $APP_BUNDLE_ID and $APP_KEYCHAIN_ACCESS_GROUP: $profile"
    printf '%s\n' "$profile"
    return 0
  fi

  find_main_app_provisioning_profile || return 1
}

app_version() {
  local pkgid version
  pkgid="$(cargo pkgid --manifest-path "$ROOT_DIR/Cargo.toml")"
  version="${pkgid##*#}"
  printf '%s\n' "${version##*@}"
}

app_build_number() {
  local count
  if count="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null)" &&
    [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]]; then
    printf '%s\n' "$count"
  else
    printf '1\n'
  fi
}

render_info_plist() {
  local version build_number escaped_version escaped_build_number
  version="${APP_VERSION:-$(app_version)}"
  build_number="${APP_BUILD_NUMBER:-$(app_build_number)}"
  escaped_version="$(printf '%s' "$version" | sed 's/[\/&\\]/\\&/g')"
  escaped_build_number="$(printf '%s' "$build_number" | sed 's/[\/&\\]/\\&/g')"

  sed \
    -e "s/@APP_VERSION@/$escaped_version/g" \
    -e "s/@APP_BUILD_NUMBER@/$escaped_build_number/g" \
    "$ROOT_DIR/src/app/Info.plist.in" >"$CONTENTS_DIR/Info.plist"
}

codesign_identity() {
  if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    printf '%s' "$CODESIGN_IDENTITY"
    return 0
  fi

  local identity
  identity="$(security find-identity -v -p codesigning |
    awk -F '"' '/Developer ID Application/ { print $2; exit }')"
  if [[ -z "$identity" ]]; then
    echo "No Developer ID Application identity found" >&2
    return 1
  fi
  printf '%s' "$identity"
}

codesign_runtime() {
  local timestamp_args=(--timestamp)
  if [[ "$IDENTITY" == "-" ]]; then
    timestamp_args=()
  fi
  codesign --force --options runtime "${timestamp_args[@]}" --sign "$IDENTITY" "$@"
}

verify_signature() {
  local path="$1"
  codesign --verify --strict --verbose=2 "$path"
}

verify_main_app_entitlement() {
  local output
  output="$(codesign -d --entitlements - "$APP_DIR" 2>/dev/null)" ||
    die "Failed to read entitlements for $APP_DIR"
  if [[ "$output" != *"$APP_KEYCHAIN_ACCESS_GROUP"* ]]; then
    echo "$output" >&2
    die "$APP_DIR is missing keychain access group $APP_KEYCHAIN_ACCESS_GROUP"
  fi
}

bundle_legacy_icon() {
  if [[ ! -f "$ICON_SOURCE" ]]; then
    echo "App icon not found: $ICON_SOURCE" >&2
    exit 1
  fi

  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"

  sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
  sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
  sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

  iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/$APP_NAME.icns"
}

compile_layered_icon() {
  if [[ ! -d "$ICON_BUNDLE" ]]; then
    return 1
  fi
  if ! xcrun --find actool >/dev/null 2>&1; then
    echo "Warning: actool not found; using legacy .icns app icon." >&2
    return 1
  fi

  local partial_info_plist icon_file icon_name
  partial_info_plist="$BUILD_DIR/AppIcon-PartialInfo.plist"

  rm -f "$partial_info_plist" "$RESOURCES_DIR/Assets.car" "$RESOURCES_DIR/AppIcon.icns"

  echo "Compiling layered app icon"
  if ! xcrun actool \
    --compile "$RESOURCES_DIR" \
    --platform macosx \
    --minimum-deployment-target "$MIN_MACOS_VERSION" \
    --app-icon AppIcon \
    --output-partial-info-plist "$partial_info_plist" \
    "$ICON_BUNDLE" >/dev/null; then
    echo "Warning: actool failed to compile $ICON_BUNDLE; using legacy .icns app icon." >&2
    return 1
  fi

  if [[ ! -f "$RESOURCES_DIR/Assets.car" || ! -f "$RESOURCES_DIR/AppIcon.icns" ]]; then
    echo "Warning: actool did not produce the expected layered app icon outputs; using legacy .icns app icon." >&2
    return 1
  fi

  icon_file="$(plutil -extract CFBundleIconFile raw "$partial_info_plist" 2>/dev/null || true)"
  icon_name="$(plutil -extract CFBundleIconName raw "$partial_info_plist" 2>/dev/null || true)"
  icon_file="${icon_file:-AppIcon}"
  icon_name="${icon_name:-$icon_file}"

  plutil -replace CFBundleIconFile -string "$icon_file" "$CONTENTS_DIR/Info.plist"
  plutil -replace CFBundleIconName -string "$icon_name" "$CONTENTS_DIR/Info.plist" 2>/dev/null ||
    plutil -insert CFBundleIconName -string "$icon_name" "$CONTENTS_DIR/Info.plist"
}

bundle_icon() {
  if compile_layered_icon; then
    return
  fi
  bundle_legacy_icon
}

bundle_completions() {
  if [[ ! -d "$FIG_AUTOCOMPLETE_DIR/build" ]]; then
    "$ROOT_DIR/scripts/fetch-fig-autocomplete.sh" >/dev/null
  fi
  if [[ ! -d "$FIG_AUTOCOMPLETE_DIR/build" ]]; then
    echo "Fig autocomplete specs not found. Run scripts/fetch-fig-autocomplete.sh." >&2
    exit 1
  fi

  rm -rf "$RESOURCES_DIR/completions"
  mkdir -p "$RESOURCES_DIR/completions/fig"
  cp -R "$FIG_AUTOCOMPLETE_DIR/build" "$RESOURCES_DIR/completions/fig/build"
  cp "$FIG_AUTOCOMPLETE_DIR/package.json" "$RESOURCES_DIR/completions/fig/package.json"
  cp "$FIG_AUTOCOMPLETE_DIR/LICENSE" "$RESOURCES_DIR/completions/fig/LICENSE"
  cp "$FIG_AUTOCOMPLETE_DIR/README.md" "$RESOURCES_DIR/completions/fig/README.md"
  if [[ ! -f "$COMMAND_DESCRIPTIONS_FILE" ]]; then
    "$ROOT_DIR/scripts/fetch-command-descriptions.sh" >/dev/null
  fi
  cp "$COMMAND_DESCRIPTIONS_FILE" "$RESOURCES_DIR/completions/command-descriptions.json"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "Required tool not found: $1"
}

plist_value() {
  local key="$1"
  local plist="$2"
  /usr/libexec/PlistBuddy -c "Print :${key}" "$plist" 2>/dev/null
}

package_version() {
  local pkgid version
  pkgid="$(cargo pkgid --manifest-path "$ROOT_DIR/Cargo.toml")"
  version="${pkgid##*#}"
  printf '%s\n' "${version##*@}"
}

version_gt() {
  local left="$1" right="$2"
  local left_major left_minor left_patch right_major right_minor right_patch

  IFS=. read -r left_major left_minor left_patch <<<"$left"
  IFS=. read -r right_major right_minor right_patch <<<"$right"

  if ((10#$left_major != 10#$right_major)); then
    ((10#$left_major > 10#$right_major))
  elif ((10#$left_minor != 10#$right_minor)); then
    ((10#$left_minor > 10#$right_minor))
  else
    ((10#$left_patch > 10#$right_patch))
  fi
}

ensure_clean_worktree() {
  git -C "$ROOT_DIR" diff --quiet ||
    die "Working tree has unstaged changes; commit or stash them before publishing"
  git -C "$ROOT_DIR" diff --cached --quiet ||
    die "Index has staged changes; commit or stash them before publishing"
}

latest_release_tag() {
  local release_tag

  require_tool gh
  release_tag="$(
    gh release list \
      --exclude-drafts \
      --limit 1 \
      --json tagName \
      --jq '.[0].tagName'
  )" || die "Unable to list GitHub releases"

  [[ -n "$release_tag" && "$release_tag" != "null" ]] || return 1
  printf '%s\n' "$release_tag"
}

ensure_git_tag_available() {
  local tag="$1"

  git -C "$ROOT_DIR" rev-parse --verify --quiet "$tag^{commit}" >/dev/null && return 0
  git -C "$ROOT_DIR" fetch --quiet origin "refs/tags/$tag:refs/tags/$tag" ||
    die "Unable to fetch release tag $tag"
}

generate_release_plan() {
  local current_version="$1"
  local plan_path notes_path version_path previous_tag compare_range prompt target_ref

  require_tool codex
  require_tool gh

  plan_path="$(mktemp "${TMPDIR:-/tmp}/vaultty-release-plan.XXXXXX")"
  notes_path="$(mktemp "${TMPDIR:-/tmp}/vaultty-release-notes.XXXXXX")"
  version_path="$(mktemp "${TMPDIR:-/tmp}/vaultty-release-version.XXXXXX")"
  target_ref="$(git -C "$ROOT_DIR" rev-parse HEAD)"

  if previous_tag="$(latest_release_tag)"; then
    ensure_git_tag_available "$previous_tag"
    compare_range="$previous_tag..$target_ref"
    prompt="Plan the next Portal release.

Repository: $ROOT_DIR
Previous release tag: $previous_tag
Current Cargo package version: $current_version
Compare range: $compare_range

Inspect the git history and diff for that range. Choose the next SemVer version based on the changes since the previous release.
Use patch for compatible fixes, minor for new user-visible behavior, and major only for intentional breaking changes.
Write concise GitHub release notes in Markdown focused on behavior, fixes, user-visible improvements, packaging, and operational changes.
Do not edit files or create commits.
Output exactly this format, with no code fence, no title, no preamble, no commit hashes, no contributor list, and no GitHub auto-generated notes references:
1. Release Notes
<release notes markdown>
2. New Semantic Version
<X.Y.Z>"
  else
    prompt="Plan the initial Portal release.

Repository: $ROOT_DIR
Current Cargo package version: $current_version
Target ref: $target_ref

Inspect the repository and recent git history. Choose the next SemVer version.
Write concise GitHub release notes in Markdown focused on behavior, fixes, user-visible improvements, packaging, and operational changes.
Do not edit files or create commits.
Output exactly this format, with no code fence, no title, no preamble, no commit hashes, no contributor list, and no GitHub auto-generated notes references:
1. Release Notes
<release notes markdown>
2. New Semantic Version
<X.Y.Z>"
  fi

  echo "Generating release plan with Codex" >&2
  codex exec \
    --cd "$ROOT_DIR" \
    --sandbox read-only \
    --config approval_policy=\"never\" \
    --color never \
    --ephemeral \
    --output-last-message "$plan_path" \
    "$prompt" \
    >&2 ||
    die "Codex release planning failed"

  [[ -s "$plan_path" ]] || die "Codex generated an empty release plan"

  awk '
    /^[[:space:]]*(1\.)?[[:space:]]*Release Notes[[:space:]]*$/ { in_notes = 1; next }
    /^[[:space:]]*(2\.)?[[:space:]]*New Semantic Version[[:space:]]*$/ { exit }
    in_notes { print }
  ' "$plan_path" >"$notes_path"

  awk '
    /^[[:space:]]*(2\.)?[[:space:]]*New Semantic Version[[:space:]]*$/ { in_version = 1; next }
    in_version && match($0, /[0-9]+\.[0-9]+\.[0-9]+/) {
      print substr($0, RSTART, RLENGTH)
      exit
    }
  ' "$plan_path" >"$version_path"

  [[ -s "$notes_path" ]] || die "Codex release plan did not include release notes"
  [[ -s "$version_path" ]] || die "Codex release plan did not include an X.Y.Z version"

  printf '%s\n%s\n' "$notes_path" "$version_path"
}

bump_cargo_version() {
  local version="$1"

  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "Release publishing requires an X.Y.Z version, got: $version"

  VERSION="$version" perl -0pi -e '
    my $version = $ENV{VERSION};
    s/(\[package\](?:(?!^\[).)*?^version\s*=\s*")[^"]+(")/$1$version$2/ms
      or die "Unable to update package.version in Cargo.toml\n";
  ' "$ROOT_DIR/Cargo.toml"

  cargo update \
    --manifest-path "$ROOT_DIR/Cargo.toml" \
    -p vaultty \
    --precise "$version" \
    >/dev/null
}

commit_release_version() {
  local version="$1"
  local tag="v$version"

  git -C "$ROOT_DIR" add Cargo.toml Cargo.lock
  git -C "$ROOT_DIR" diff --cached --quiet &&
    die "Cargo.toml and Cargo.lock were unchanged after version bump"

  git -C "$ROOT_DIR" commit -m "$tag" >&2
}

push_current_branch() {
  local branch

  branch="$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)"
  [[ "$branch" != "HEAD" ]] || die "Cannot push release commit from detached HEAD"
  git -C "$ROOT_DIR" push >&2
}

existing_release_notes_path() {
  local tag="$1"
  local notes_path

  require_tool gh
  notes_path="$(mktemp "${TMPDIR:-/tmp}/vaultty-existing-release-notes.XXXXXX")"
  gh release view "$tag" --json body --jq '.body // ""' >"$notes_path" ||
    die "--clobber requires an existing GitHub release $tag"
  printf '%s\n' "$notes_path"
}

prepare_release() {
  local current_version release_plan version_path

  require_tool git
  require_tool cargo
  git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null ||
    die "scripts/build.sh must run inside a git repository"
  git -C "$ROOT_DIR" rev-parse --verify HEAD >/dev/null 2>&1 ||
    die "Create an initial commit before publishing"
  if ! git -C "$ROOT_DIR" remote get-url origin >/dev/null 2>&1 && [[ -z "${GH_REPO:-}" ]]; then
    die "Set a git origin remote or GH_REPO before publishing"
  fi
  ensure_clean_worktree

  echo "Validating protocol compatibility" >&2
  "$ROOT_DIR/scripts/validate-protocol-compatibility.sh"

  current_version="$(package_version)"
  if [[ "$CLOBBER_RELEASE" == true ]]; then
    RELEASE_VERSION="$current_version"
    RELEASE_NOTES_PATH="$(existing_release_notes_path "v$RELEASE_VERSION")"
    return
  fi

  release_plan="$(generate_release_plan "$current_version")"
  RELEASE_NOTES_PATH="$(printf '%s\n' "$release_plan" | sed -n '1p')"
  version_path="$(printf '%s\n' "$release_plan" | sed -n '2p')"
  RELEASE_VERSION="$(<"$version_path")"

  version_gt "$RELEASE_VERSION" "$current_version" ||
    die "Codex proposed $RELEASE_VERSION, which is not newer than current Cargo version $current_version"
  git -C "$ROOT_DIR" rev-parse --verify --quiet "v$RELEASE_VERSION^{commit}" >/dev/null &&
    die "Tag v$RELEASE_VERSION already exists"

  bump_cargo_version "$RELEASE_VERSION"
  commit_release_version "$RELEASE_VERSION"
  push_current_branch
}

create_dmg() {
  local app_path="$1"
  local dmg_path="$2"
  local app_bundle_name

  app_bundle_name="$(basename "$app_path")"
  rm -f "$dmg_path"
  mkdir -p "$(dirname "$dmg_path")"
  require_tool create-dmg
  create-dmg \
    --volname "$APP_NAME" \
    --window-pos 120 120 \
    --window-size 600 400 \
    --icon-size 128 \
    --icon "$app_bundle_name" 155 170 \
    --app-drop-link 445 170 \
    --format ULFO \
    --filesystem HFS+ \
    --hdiutil-quiet \
    "$dmg_path" \
    "$app_path" \
    >&2
}

notarize_dmg() {
  local dmg_path="$1"
  local team_id="${APPLE_TEAM_ID:-}"

  [[ -n "${APPLE_USERNAME:-}" ]] || die "APPLE_USERNAME is required for notarization"
  [[ -n "${APPLE_PASSWORD:-}" ]] || die "APPLE_PASSWORD is required for notarization"

  if [[ -z "$team_id" ]]; then
    if [[ "$IDENTITY" =~ \(([A-Z0-9]+)\)[[:space:]]*$ ]]; then
      team_id="${BASH_REMATCH[1]}"
    else
      die "Unable to extract Apple team ID from codesign identity"
    fi
  fi

  require_tool xcrun
  /usr/bin/xcrun notarytool submit \
    --apple-id "$APPLE_USERNAME" \
    --team-id "$team_id" \
    --password "$APPLE_PASSWORD" \
    --wait \
    "$dmg_path" \
    >&2
  /usr/bin/xcrun stapler staple "$dmg_path" >&2
}

publish_github_release() {
  local tag="$1"
  local version="$2"
  local dmg_path="$3"
  local release_notes_path="$4"
  local target_ref

  require_tool gh
  target_ref="$(git -C "$ROOT_DIR" rev-parse HEAD)"

  if [[ "$CLOBBER_RELEASE" == true ]]; then
    if gh release view "$tag" >/dev/null 2>&1; then
      gh release delete "$tag" --yes --cleanup-tag >&2 ||
        die "Unable to clobber existing GitHub release $tag"
    fi
  fi

  gh release create "$tag" \
    --draft \
    --notes-file "$release_notes_path" \
    --target "$target_ref" \
    --title "$APP_NAME $version" \
    "$dmg_path#$(basename "$dmg_path")" \
    >&2
  gh release edit "$tag" --draft=false >&2
}

run_install_command() {
  if [[ -w /Applications ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

install_app() (
  local source_app="$1"
  local target_app="/Applications/$APP_NAME.app"
  local staged_app="/Applications/.$APP_NAME.app.install.$$"
  local backup_app=""

  # shellcheck disable=SC2329
  cleanup_install() {
    if [[ -n "$backup_app" && -d "$backup_app" ]]; then
      if [[ ! -d "$target_app" ]]; then
        run_install_command mv "$backup_app" "$target_app" || true
      else
        run_install_command rm -rf "$backup_app" || true
      fi
    fi
    [[ ! -d "$staged_app" ]] || run_install_command rm -rf "$staged_app" || true
  }
  trap cleanup_install EXIT

  run_install_command rm -rf "$staged_app"
  run_install_command ditto "$source_app" "$staged_app"
  if [[ -d "$target_app" ]]; then
    backup_app="/Applications/.$APP_NAME.app.previous.$$"
    run_install_command mv "$target_app" "$backup_app"
  fi
  run_install_command mv "$staged_app" "$target_app"
  if [[ -n "$backup_app" && -d "$backup_app" ]]; then
    run_install_command rm -rf "$backup_app"
    backup_app=""
  fi

  printf '%s\n' "$target_app"
)

kill_existing() {
  pkill -x "$EXECUTABLE_NAME" 2>/dev/null || true
  for _ in {1..50}; do
    pgrep -x "$EXECUTABLE_NAME" >/dev/null || return 0
    sleep 0.1
  done
  pkill -9 -x "$EXECUTABLE_NAME" 2>/dev/null || true
}

RELEASE_VERSION=""
RELEASE_NOTES_PATH=""
if [[ "$PUBLISH_RELEASE" == true ]]; then
  prepare_release
fi

IDENTITY="$(codesign_identity)"
MAIN_APP_PROVISIONING_PROFILE=""
if [[ "$IDENTITY" != "-" ]]; then
  if ! MAIN_APP_PROVISIONING_PROFILE="$(resolve_main_app_provisioning_profile)"; then
    die "No Developer ID provisioning profile found for $APP_BUNDLE_ID with keychain access group $APP_KEYCHAIN_ACCESS_GROUP. Set VAULTTY_PROVISIONING_PROFILE to its path."
  fi
fi

case "$CONFIGURATION" in
  debug)
    CARGO_FLAGS=()
    SWIFT_FLAGS=(-Onone -g)
    RUST_BIN_DIR="$ROOT_DIR/target/debug"
    ;;
  release)
    CARGO_FLAGS=(--release)
    SWIFT_FLAGS=(-O)
    RUST_BIN_DIR="$ROOT_DIR/target/release"
    ;;
  *)
    echo "Unknown configuration: $CONFIGURATION" >&2
    exit 1
    ;;
esac

echo "Building Rust helpers"
export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS_VERSION"
cargo build ${CARGO_FLAGS[@]+"${CARGO_FLAGS[@]}"} --bin portal-sessiond --bin portal-session-bridge

echo "Building Swift package dependencies"
swift build \
  --package-path "$ROOT_DIR" \
  --configuration "$CONFIGURATION" \
  --build-path "$SWIFT_DEPS_BUILD_PATH" \
  --target VaulttySwiftDependencies
SWIFT_DEPS_BIN_DIR="$(swift build \
  --package-path "$ROOT_DIR" \
  --configuration "$CONFIGURATION" \
  --build-path "$SWIFT_DEPS_BUILD_PATH" \
  --show-bin-path)"
SWIFT_DEPS_LINK_ARGS=(-I "$SWIFT_DEPS_BIN_DIR/Modules")
while IFS= read -r object_file; do
  SWIFT_DEPS_LINK_ARGS+=("$object_file")
done < <(
  find "$SWIFT_DEPS_BIN_DIR" \
    \( -path '*/AppUpdater.build/*.o' -o -path '*/Version.build/*.o' \) \
    -print |
    sort
)
[[ "${#SWIFT_DEPS_LINK_ARGS[@]}" -gt 1 ]] ||
  die "Swift package dependencies did not produce linkable object files in $SWIFT_DEPS_BIN_DIR"

echo "Building Portal app bundle"
rm -rf "$APP_DIR"
mkdir -p \
  "$MACOS_DIR" \
  "$RESOURCES_DIR" \
  "$HELPERS_DIR" \
  "$FRAMEWORKS_DIR"
render_info_plist
cp "$RUST_BIN_DIR/portal-sessiond" "$SESSIOND_HELPER"
cp "$RUST_BIN_DIR/portal-session-bridge" "$SESSION_BRIDGE_HELPER"
if [[ -n "$MAIN_APP_PROVISIONING_PROFILE" ]]; then
  cp "$MAIN_APP_PROVISIONING_PROFILE" "$CONTENTS_DIR/embedded.provisionprofile"
fi
bundle_icon
bundle_completions

GHOSTTY_SWIFT_LINK_ARGS=()
GHOSTTY_BRIDGE_FLAGS=(-DVAULTTY_WITH_GHOSTTY=0)

if [[ "$WITH_GHOSTTY_VT" == true ]]; then
  GHOSTTY_PREFIX="$ROOT_DIR/target/ghostty-vt"
  GHOSTTY_LIB="$(find "$GHOSTTY_PREFIX" -type f \( -name 'libghostty-vt.dylib' -o -name 'libghostty-vt.a' \) | head -n 1 || true)"
  if [[ -z "$GHOSTTY_LIB" ]]; then
    echo "libghostty-vt not found. Run scripts/build-libghostty-vt.sh first." >&2
    exit 1
  fi
  GHOSTTY_INCLUDE="$GHOSTTY_PREFIX/include"
  if [[ ! -d "$GHOSTTY_INCLUDE" ]]; then
    GHOSTTY_INCLUDE="$ROOT_DIR/target/vendor/ghostty/include"
  fi
  if [[ "$GHOSTTY_LIB" == *.dylib ]]; then
    cp "$GHOSTTY_LIB" "$GHOSTTY_DYLIB"
    GHOSTTY_SWIFT_LINK_ARGS=(
      -L "$FRAMEWORKS_DIR"
      -lghostty-vt
      -Xlinker -rpath
      -Xlinker @executable_path/../Frameworks
    )
    GHOSTTY_BRIDGE_FLAGS=(-DVAULTTY_WITH_GHOSTTY=1 -I"$GHOSTTY_INCLUDE")
    clang \
      -Os \
      -target "arm64-apple-macos$MIN_MACOS_VERSION" \
      -I"$GHOSTTY_INCLUDE" \
      "$ROOT_DIR/src/ghostty_probe/main.c" \
      -L"$FRAMEWORKS_DIR" \
      -lghostty-vt \
      -Wl,-rpath,@loader_path/../Frameworks \
      -o "$GHOSTTY_PROBE"
  else
    clang \
      -Os \
      -target "arm64-apple-macos$MIN_MACOS_VERSION" \
      -I"$GHOSTTY_INCLUDE" \
      "$ROOT_DIR/src/ghostty_probe/main.c" \
      "$GHOSTTY_LIB" \
      -o "$GHOSTTY_PROBE"
  fi
fi

clang \
  -Os \
  -target "arm64-apple-macos$MIN_MACOS_VERSION" \
  "${GHOSTTY_BRIDGE_FLAGS[@]}" \
  -c "$ROOT_DIR/src/app/GhosttyOscBridge.c" \
  -o "$GHOSTTY_BRIDGE_OBJECT"

SWIFTC_COMMAND=(
  swiftc
  "${SWIFT_FLAGS[@]}" \
  -parse-as-library \
  -target "arm64-apple-macosx$MIN_MACOS_VERSION" \
  -framework AppKit \
  -framework JavaScriptCore \
  "${SWIFT_DEPS_LINK_ARGS[@]}" \
  "$ROOT_DIR/src/app/main.swift" \
  "$ROOT_DIR/src/core/SessionTypes.swift" \
  "$ROOT_DIR/src/core/SessionCatalog.swift" \
  "$ROOT_DIR/src/core/SessionWireProtocol.swift" \
  "$ROOT_DIR/src/core/RemoteProtocol.swift" \
  "$ROOT_DIR/src/core/RemoteSessionCreationClient.swift" \
  "$ROOT_DIR/src/core/RemoteTerminalSessionClient.swift" \
  "$ROOT_DIR/src/core/VaulttyCommandEnvelope.swift" \
  "$ROOT_DIR/src/core/RelayCrypto.swift" \
  "$ROOT_DIR/src/core/ICloudKeychainRootKey.swift" \
  "$ROOT_DIR/src/core/RelayClient.swift" \
  "$ROOT_DIR/src/app/PtySession.swift" \
  "$ROOT_DIR/src/app/MacRemoteAccessController.swift" \
  "$ROOT_DIR/src/app/RelayTerminalSession.swift" \
  "$ROOT_DIR/src/core/CommandLifecycle.swift" \
  "$ROOT_DIR/src/app/Ansi.swift" \
  "$ROOT_DIR/src/app/GitDirectoryState.swift" \
  "$ROOT_DIR/src/app/Completion.swift" \
  "$ROOT_DIR/src/app/TerminalViewController.swift" \
  "$GHOSTTY_BRIDGE_OBJECT"
)

swiftc \
  "${SWIFT_FLAGS[@]}" \
  -parse-as-library \
  -target "arm64-apple-macosx$MIN_MACOS_VERSION" \
  "$ROOT_DIR/src/remote_agent/main.swift" \
  "$ROOT_DIR/src/core/SessionTypes.swift" \
  "$ROOT_DIR/src/core/SessionWireProtocol.swift" \
  "$ROOT_DIR/src/core/RemoteProtocol.swift" \
  "$ROOT_DIR/src/core/RemoteSessionCreationClient.swift" \
  "$ROOT_DIR/src/core/VaulttyCommandEnvelope.swift" \
  "$ROOT_DIR/src/core/RelayCrypto.swift" \
  "$ROOT_DIR/src/core/ICloudKeychainRootKey.swift" \
  "$ROOT_DIR/src/core/RelayClient.swift" \
  "$ROOT_DIR/src/app/PtySession.swift" \
  "$ROOT_DIR/src/app/MacRemoteAccessController.swift" \
  -o "$HELPERS_DIR/portal-remote-agent"
if [[ "${#GHOSTTY_SWIFT_LINK_ARGS[@]}" -gt 0 ]]; then
  SWIFTC_COMMAND+=("${GHOSTTY_SWIFT_LINK_ARGS[@]}")
fi
SWIFTC_COMMAND+=(
  -o "$EXECUTABLE"
)
"${SWIFTC_COMMAND[@]}"

echo "Signing with $IDENTITY"
if [[ -f "$GHOSTTY_DYLIB" ]]; then
  codesign_runtime "$GHOSTTY_DYLIB"
  verify_signature "$GHOSTTY_DYLIB"
fi
codesign_runtime \
  --identifier "$SESSIOND_HELPER_ID" \
  "$SESSIOND_HELPER"
verify_signature "$SESSIOND_HELPER"
codesign_runtime \
  --identifier "$SESSION_BRIDGE_ID" \
  "$SESSION_BRIDGE_HELPER"
verify_signature "$SESSION_BRIDGE_HELPER"
codesign_runtime \
  --identifier "$REMOTE_AGENT_ID" \
  "$HELPERS_DIR/portal-remote-agent"
verify_signature "$HELPERS_DIR/portal-remote-agent"
if [[ -x "$GHOSTTY_PROBE" ]]; then
  codesign_runtime \
    --identifier "$GHOSTTY_PROBE_ID" \
    "$GHOSTTY_PROBE"
  verify_signature "$GHOSTTY_PROBE"
fi
codesign_runtime \
  --entitlements "$ROOT_DIR/src/app/vaultty.entitlements" \
  --identifier "$APP_BUNDLE_ID" \
  "$APP_DIR"
verify_signature "$APP_DIR"
verify_main_app_entitlement
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

FINAL_APP="$APP_DIR"
BUILT_VERSION="$(plist_value CFBundleShortVersionString "$APP_DIR/Contents/Info.plist")"
[[ -n "$BUILT_VERSION" ]] || die "Unable to read CFBundleShortVersionString from $APP_DIR"

if [[ "$PUBLISH_RELEASE" == true && "$BUILT_VERSION" != "$RELEASE_VERSION" ]]; then
  die "Built app version $BUILT_VERSION does not match planned release version $RELEASE_VERSION"
fi

if [[ "$CREATE_DMG" == true ]]; then
  if [[ -z "$OUTPUT_PATH" ]]; then
    OUTPUT_PATH="$ROOT_DIR/target/$APP_NAME-${RELEASE_VERSION:-$BUILT_VERSION}.dmg"
  fi
  mkdir -p "$(dirname "$OUTPUT_PATH")"
  OUTPUT_DIR="$(cd "$(dirname "$OUTPUT_PATH")" && pwd)"
  FINAL_DMG="$OUTPUT_DIR/$(basename "$OUTPUT_PATH")"

  echo "Creating $FINAL_DMG"
  create_dmg "$APP_DIR" "$FINAL_DMG"

  if [[ "$NOTARIZE_DMG" == true ]]; then
    echo "Notarizing $FINAL_DMG"
    notarize_dmg "$FINAL_DMG"
  fi

  if [[ "$PUBLISH_RELEASE" == true ]]; then
    publish_github_release "v$RELEASE_VERSION" "$RELEASE_VERSION" "$FINAL_DMG" "$RELEASE_NOTES_PATH"
  fi
fi

if [[ "$INSTALL_APP" == true ]]; then
  kill_existing
  FINAL_APP="$(install_app "$APP_DIR")"
fi

printf '%s\n' "$FINAL_APP"
if [[ "${FINAL_DMG:-}" != "" ]]; then
  printf '%s\n' "$FINAL_DMG"
fi

if [[ "$RUN_APP" == true ]]; then
  kill_existing
  if [[ "${#APP_ARGS[@]}" -gt 0 ]]; then
    exec "$FINAL_APP/Contents/MacOS/$EXECUTABLE_NAME" "${APP_ARGS[@]}"
  fi
  open "$FINAL_APP"
fi
