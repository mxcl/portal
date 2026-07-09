#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAULT_DIR="${VAULT_DIR:-$HOME/src/automic-vault}"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="Vaultty"
APP_BUNDLE_ID="com.automicvault.vaultty"
ENV_HELPER_ID="com.automicvault.vaultty.env"
SESSIOND_HELPER_ID="com.automicvault.vaultty.sessiond"
SESSION_BRIDGE_ID="com.automicvault.vaultty.session-bridge"
ENV_HELPER_APP_NAME="VaulttyEnv"
GHOSTTY_PROBE_ID="com.automicvault.vaultty.ghostty-probe"
DOTENV_KEYCHAIN_ACCESS_GROUP="${VAULTTY_DOTENV_KEYCHAIN_ACCESS_GROUP:-${AV_DOTENV_KEYCHAIN_ACCESS_GROUP:-ZU76A67LGU.com.automicvault.dotenv}}"
MIN_MACOS_VERSION="26.1"
BUILD_DIR="$ROOT_DIR/target/app/$CONFIGURATION"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
EXECUTABLE="$MACOS_DIR/$APP_NAME"
ENV_HELPER_APP_DIR="$HELPERS_DIR/$ENV_HELPER_APP_NAME.app"
ENV_HELPER_APP_CONTENTS_DIR="$ENV_HELPER_APP_DIR/Contents"
ENV_HELPER_APP_MACOS_DIR="$ENV_HELPER_APP_CONTENTS_DIR/MacOS"
ENV_HELPER_APP_RESOURCES_DIR="$ENV_HELPER_APP_CONTENTS_DIR/Resources"
ENV_HELPER="$ENV_HELPER_APP_MACOS_DIR/vaultty-env"
SESSIOND_HELPER="$HELPERS_DIR/vaultty-sessiond"
SESSION_BRIDGE_HELPER="$HELPERS_DIR/vaultty-session-bridge"
ENV_HELPER_ENTITLEMENTS="$BUILD_DIR/vaultty-env.entitlements"
GHOSTTY_PROBE="$HELPERS_DIR/vaultty-ghostty-probe"
GHOSTTY_DYLIB="$FRAMEWORKS_DIR/libghostty-vt.dylib"
GHOSTTY_BRIDGE_OBJECT="$BUILD_DIR/GhosttyOscBridge.o"
ICON_BUNDLE="$ROOT_DIR/assets/AppIcon.icon"
ICON_SOURCE="$ICON_BUNDLE/Assets/Vaultty.png"
ICONSET_DIR="$BUILD_DIR/$APP_NAME.iconset"
FIG_AUTOCOMPLETE_DIR="$ROOT_DIR/target/vendor/fig-autocomplete/package"
COMMAND_DESCRIPTIONS_FILE="$ROOT_DIR/src/app/command-descriptions.json"

usage() {
  cat <<'EOF'
Usage: scripts/build-app.sh [--debug|--release] [--with-ghostty-vt]

Build and codesign Vaultty.app using the Developer ID identity associated with
~/src/automic-vault.

Options:
  --with-ghostty-vt  Require target/ghostty-vt and bundle a libghostty-vt probe.
EOF
}

WITH_GHOSTTY_VT=false

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
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

BUILD_DIR="$ROOT_DIR/target/app/$CONFIGURATION"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
EXECUTABLE="$MACOS_DIR/$APP_NAME"
ENV_HELPER_APP_DIR="$HELPERS_DIR/$ENV_HELPER_APP_NAME.app"
ENV_HELPER_APP_CONTENTS_DIR="$ENV_HELPER_APP_DIR/Contents"
ENV_HELPER_APP_MACOS_DIR="$ENV_HELPER_APP_CONTENTS_DIR/MacOS"
ENV_HELPER_APP_RESOURCES_DIR="$ENV_HELPER_APP_CONTENTS_DIR/Resources"
ENV_HELPER="$ENV_HELPER_APP_MACOS_DIR/vaultty-env"
SESSIOND_HELPER="$HELPERS_DIR/vaultty-sessiond"
SESSION_BRIDGE_HELPER="$HELPERS_DIR/vaultty-session-bridge"
ENV_HELPER_ENTITLEMENTS="$BUILD_DIR/vaultty-env.entitlements"
GHOSTTY_PROBE="$HELPERS_DIR/vaultty-ghostty-probe"
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

env_file_value() {
  local key="$1"
  local file="$VAULT_DIR/.env"
  [[ -f "$file" ]] || return 1
  awk -F= -v wanted="$key" '
    $1 == wanted {
      sub(/^[^=]*=/, "")
      print
      exit
    }
  ' "$file"
}

die() {
  echo "$*" >&2
  exit 1
}

normalize_profile_path() {
  local path="$1"
  path="$(unquote_env_value "$path")"
  if [[ "$path" == "~/"* ]]; then
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

profile_matches_env_helper() {
  local profile_path="$1"
  local decoded_path app_identifier team_identifier expected_app_identifier keychain_groups

  decoded_path="$(mktemp "${TMPDIR:-/tmp}/vaultty-profile.XXXXXX")"
  if ! decode_provisioning_profile "$profile_path" "$decoded_path"; then
    rm -f "$decoded_path"
    return 1
  fi

  app_identifier="$(profile_plist_value "$decoded_path" ":Entitlements:com.apple.application-identifier")"
  team_identifier="$(profile_plist_value "$decoded_path" ":Entitlements:com.apple.developer.team-identifier")"
  keychain_groups="$(profile_plist_value "$decoded_path" ":Entitlements:keychain-access-groups")"
  rm -f "$decoded_path"

  expected_app_identifier="${team_identifier}.${ENV_HELPER_ID}"
  [[ -n "$team_identifier" ]] || return 1
  [[ "$app_identifier" == "$expected_app_identifier" ]] || return 1
  [[ "$DOTENV_KEYCHAIN_ACCESS_GROUP" == "${team_identifier}."* ]] || return 1
  [[ "$keychain_groups" == *"$DOTENV_KEYCHAIN_ACCESS_GROUP"* ||
     "$keychain_groups" == *"${team_identifier}.*"* ]]
}

describe_provisioning_profile() {
  local profile_path="$1"
  local decoded_path name app_identifier team_identifier keychain_groups

  decoded_path="$(mktemp "${TMPDIR:-/tmp}/vaultty-profile.XXXXXX")"
  if ! decode_provisioning_profile "$profile_path" "$decoded_path"; then
    rm -f "$decoded_path"
    printf '  %s: unable to decode\n' "$profile_path" >&2
    return
  fi

  name="$(profile_plist_value "$decoded_path" ":Name")"
  app_identifier="$(profile_plist_value "$decoded_path" ":Entitlements:com.apple.application-identifier")"
  team_identifier="$(profile_plist_value "$decoded_path" ":Entitlements:com.apple.developer.team-identifier")"
  keychain_groups="$(profile_plist_value "$decoded_path" ":Entitlements:keychain-access-groups" | tr '\n' ' ')"
  rm -f "$decoded_path"

  printf '  %s\n' "$profile_path" >&2
  printf '    name: %s\n' "${name:-unknown}" >&2
  printf '    application-identifier: %s\n' "${app_identifier:-missing}" >&2
  printf '    team: %s\n' "${team_identifier:-missing}" >&2
  printf '    keychain-access-groups: %s\n' "${keychain_groups:-missing}" >&2
}

print_env_helper_profile_diagnostics() {
  local search_dir="$HOME/Library/MobileDevice/Provisioning Profiles"
  local profile found=false

  printf 'No matching Developer ID provisioning profile found for %s.\n' "$ENV_HELPER_ID" >&2
  printf 'Required application-identifier: ZU76A67LGU.%s\n' "$ENV_HELPER_ID" >&2
  printf 'Required keychain access group: %s\n' "$DOTENV_KEYCHAIN_ACCESS_GROUP" >&2
  printf 'Searched: %s\n' "$search_dir" >&2

  if [[ -d "$search_dir" ]]; then
    while IFS= read -r profile; do
      if [[ "$found" == "false" ]]; then
        printf 'Installed profiles:\n' >&2
        found=true
      fi
      describe_provisioning_profile "$profile"
    done < <(find "$search_dir" -type f \( -name '*.provisionprofile' -o -name '*.mobileprovision' \) 2>/dev/null | sort)
  fi

  if [[ "$found" == "false" ]]; then
    printf 'Installed profiles: none\n' >&2
  fi

  printf 'Set VAULTTY_ENV_PROVISIONING_PROFILE to an explicit profile path if it is stored elsewhere.\n' >&2
}

find_env_helper_provisioning_profile() {
  local search_dir="$HOME/Library/MobileDevice/Provisioning Profiles"
  local profile
  [[ -d "$search_dir" ]] || return 1

  while IFS= read -r profile; do
    if profile_matches_env_helper "$profile"; then
      printf '%s\n' "$profile"
      return 0
    fi
  done < <(find "$search_dir" -type f \( -name '*.provisionprofile' -o -name '*.mobileprovision' \) 2>/dev/null | sort)

  return 1
}

resolve_env_helper_provisioning_profile() {
  local profile="${VAULTTY_ENV_PROVISIONING_PROFILE:-${AV_VAULTTY_ENV_PROVISIONING_PROFILE:-}}"
  if [[ -n "$profile" ]]; then
    profile="$(normalize_profile_path "$profile")"
    [[ -f "$profile" ]] || die "Vaultty env helper provisioning profile not found: $profile"
    if ! profile_matches_env_helper "$profile"; then
      die "Vaultty env helper provisioning profile does not match $ENV_HELPER_ID and $DOTENV_KEYCHAIN_ACCESS_GROUP: $profile"
    fi
    printf '%s\n' "$profile"
    return 0
  fi

  find_env_helper_provisioning_profile || return 1
}

write_env_helper_entitlements() {
  cat >"$ENV_HELPER_ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
"http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>keychain-access-groups</key>
  <array>
    <string>${DOTENV_KEYCHAIN_ACCESS_GROUP}</string>
  </array>
</dict>
</plist>
PLIST
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

write_env_helper_info_plist() {
  local version build_number
  version="${APP_VERSION:-$(app_version)}"
  build_number="${APP_BUILD_NUMBER:-$(app_build_number)}"

  cat >"$ENV_HELPER_APP_CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
"http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>vaultty-env</string>
  <key>CFBundleIdentifier</key>
  <string>${ENV_HELPER_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Vaultty Env</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${version}</string>
  <key>CFBundleVersion</key>
  <string>${build_number}</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MIN_MACOS_VERSION}</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST
}

codesign_identity() {
  if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    printf '%s' "$CODESIGN_IDENTITY"
    return 0
  fi

  local team_common_name
  team_common_name="$(env_file_value TEAM_COMMON_NAME || true)"
  team_common_name="$(unquote_env_value "$team_common_name")"
  if [[ -z "$team_common_name" ]]; then
    echo "Unable to read TEAM_COMMON_NAME from $VAULT_DIR/.env" >&2
    return 1
  fi

  local identity
  identity="$(security find-identity -v -p codesigning |
    sed -n "s/.*\"\(Developer ID Application: ${team_common_name} ([^\"]*)\)\".*/\1/p" |
    head -n 1)"
  if [[ -z "$identity" ]]; then
    echo "No Developer ID Application identity found for $team_common_name" >&2
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

verify_env_helper_entitlement() {
  local output
  output="$(codesign -d --entitlements - "$ENV_HELPER_APP_DIR" 2>/dev/null)" ||
    die "Failed to read entitlements for $ENV_HELPER_APP_DIR"
  if [[ "$output" != *"$DOTENV_KEYCHAIN_ACCESS_GROUP"* ]]; then
    echo "$output" >&2
    die "$ENV_HELPER_APP_DIR is missing keychain access group $DOTENV_KEYCHAIN_ACCESS_GROUP"
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

IDENTITY="$(codesign_identity)"
ENV_HELPER_PROVISIONING_PROFILE=""
if [[ "$IDENTITY" != "-" ]]; then
  if ! ENV_HELPER_PROVISIONING_PROFILE="$(resolve_env_helper_provisioning_profile)"; then
    print_env_helper_profile_diagnostics
    exit 1
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
cargo build ${CARGO_FLAGS[@]+"${CARGO_FLAGS[@]}"} --bin vaultty-env --bin vaultty-sessiond --bin vaultty-session-bridge

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

echo "Building Vaultty app bundle"
rm -rf "$APP_DIR"
mkdir -p \
  "$MACOS_DIR" \
  "$RESOURCES_DIR" \
  "$HELPERS_DIR" \
  "$FRAMEWORKS_DIR" \
  "$ENV_HELPER_APP_MACOS_DIR" \
  "$ENV_HELPER_APP_RESOURCES_DIR"
render_info_plist
write_env_helper_info_plist
cp "$RUST_BIN_DIR/vaultty-env" "$ENV_HELPER"
cp "$RUST_BIN_DIR/vaultty-sessiond" "$SESSIOND_HELPER"
cp "$RUST_BIN_DIR/vaultty-session-bridge" "$SESSION_BRIDGE_HELPER"
if [[ -n "$ENV_HELPER_PROVISIONING_PROFILE" ]]; then
  cp "$ENV_HELPER_PROVISIONING_PROFILE" "$ENV_HELPER_APP_CONTENTS_DIR/embedded.provisionprofile"
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
  "$ROOT_DIR/src/app/PtySession.swift" \
  "$ROOT_DIR/src/app/Ansi.swift" \
  "$ROOT_DIR/src/app/GitDirectoryState.swift" \
  "$ROOT_DIR/src/app/Completion.swift" \
  "$ROOT_DIR/src/app/TerminalViewController.swift" \
  "$GHOSTTY_BRIDGE_OBJECT"
)
if [[ "${#GHOSTTY_SWIFT_LINK_ARGS[@]}" -gt 0 ]]; then
  SWIFTC_COMMAND+=("${GHOSTTY_SWIFT_LINK_ARGS[@]}")
fi
SWIFTC_COMMAND+=(
  -o "$EXECUTABLE"
)
"${SWIFTC_COMMAND[@]}"

echo "Signing with $IDENTITY"
write_env_helper_entitlements
codesign_runtime \
  --entitlements "$ENV_HELPER_ENTITLEMENTS" \
  --identifier "$ENV_HELPER_ID" \
  "$ENV_HELPER_APP_DIR"
verify_signature "$ENV_HELPER_APP_DIR"
verify_env_helper_entitlement
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
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "$APP_DIR"
