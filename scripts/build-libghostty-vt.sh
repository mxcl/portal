#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY_VERSION="1.3.1"
GHOSTTY_TAG="v$GHOSTTY_VERSION"
GHOSTTY_DIR="$ROOT_DIR/target/vendor/ghostty"
INSTALL_DIR="$ROOT_DIR/target/ghostty-vt"
LOG_DIR="$ROOT_DIR/target/logs"
LOG_FILE="$LOG_DIR/libghostty-vt-build.log"
GLOBAL_CACHE="$ROOT_DIR/target/zig-cache-0.15"
WRAPPER="$ROOT_DIR/scripts/zig-0.15-macos15-wrapper.sh"

mkdir -p "$LOG_DIR" "$(dirname "$GHOSTTY_DIR")"

if [[ ! -d "$GHOSTTY_DIR/.git" ]]; then
  git clone --depth 1 --branch "$GHOSTTY_TAG" \
    https://github.com/ghostty-org/ghostty.git "$GHOSTTY_DIR"
fi

ZIG="$("$ROOT_DIR/scripts/fetch-zig-0.15.2.sh")"
rm -rf "$GHOSTTY_DIR/.zig-cache" "$GLOBAL_CACHE" "$INSTALL_DIR"
mkdir -p "$GLOBAL_CACHE" "$INSTALL_DIR"
SDKROOT_PATH="$(xcrun --show-sdk-path)"

echo "Patching Ghostty build for lib-vt-only builds" | tee "$LOG_FILE"
perl -0pi -e 's/if \(config\.target\.result\.os\.tag\.isDarwin\(\)\) \{\n        \/\/ Ghostty xcframework/if (config.target.result.os.tag.isDarwin() and\n        (config.emit_xcframework or config.emit_macos_app))\n    {\n        \/\/ Ghostty xcframework/' \
  "$GHOSTTY_DIR/build.zig"
perl -0pi -e 's/if \(config\.target\.result\.os\.tag\.isDarwin\(\)\) \{\n            const xcframework_native/if (config.target.result.os.tag.isDarwin() and config.emit_macos_app) {\n            const xcframework_native/' \
  "$GHOSTTY_DIR/build.zig"

echo "Fetching Ghostty Zig package dependencies" | tee -a "$LOG_FILE"
while IFS= read -r url; do
  [[ -n "$url" ]] || continue
  [[ "$url" == *COMMIT* ]] && continue
  echo "fetch $url" >>"$LOG_FILE"
  "$ZIG" fetch --global-cache-dir "$GLOBAL_CACHE" "$url" >>"$LOG_FILE" 2>&1
done < <(
  find "$GHOSTTY_DIR" -name build.zig.zon -print0 |
    xargs -0 perl -ne 'print "$1\n" if /\.url = "([^"]+)"/' |
    sort -u
)

echo "Generating Zig build runner" | tee -a "$LOG_FILE"
set +e
(
  cd "$GHOSTTY_DIR"
  "$ZIG" build lib-vt \
    --global-cache-dir "$GLOBAL_CACHE" \
    -Dtarget=aarch64-macos.15.0 \
    -Doptimize=ReleaseFast \
    -Demit-xcframework=false \
    -Demit-macos-app=false \
    --prefix "$INSTALL_DIR"
) >>"$LOG_FILE" 2>&1
set -e

runner_dir="$(find "$GHOSTTY_DIR/.zig-cache/o" -maxdepth 2 -type f -name build_zcu.o -print0 |
  xargs -0 ls -t |
  head -n 1 |
  xargs dirname)"
runner="$runner_dir/build"
compiler_rt="$(find "$GLOBAL_CACHE/o" "$HOME/.cache/zig/o" -name libcompiler_rt.a -print 2>/dev/null | head -n 1)"
if [[ -z "$compiler_rt" ]]; then
  echo "Unable to locate Zig compiler_rt for build runner relink" >&2
  exit 1
fi

echo "Relinking Zig build runner for macOS 15 host" | tee -a "$LOG_FILE"
clang -target arm64-apple-macos15 -isysroot "$SDKROOT_PATH" \
  "$runner_dir/build_zcu.o" "$compiler_rt" -o "$runner" >>"$LOG_FILE" 2>&1

echo "Building libghostty-vt" | tee -a "$LOG_FILE"
set +e
(
  cd "$GHOSTTY_DIR"
  PORTAL_REAL_ZIG="$ZIG" \
  SDKROOT="$SDKROOT_PATH" \
  "$runner" \
    "$WRAPPER" \
    "$ROOT_DIR/target/tools/zig-aarch64-macos-0.15.2/lib" \
    "$GHOSTTY_DIR" \
    "$GHOSTTY_DIR/.zig-cache" \
    "$GLOBAL_CACHE" \
    -Zportalghosttyvt01 \
    lib-vt \
    -Dtarget=aarch64-macos.15.0 \
    -Doptimize=ReleaseFast \
    -Demit-xcframework=false \
    -Demit-macos-app=false \
    --prefix "$INSTALL_DIR" \
    --verbose-link
) >>"$LOG_FILE" 2>&1
build_status=$?
set -e

if [[ $build_status -ne 0 ]] && rg -q 'zig ld -dynamic .*libghostty-vt' "$LOG_FILE"; then
  echo "Relinking libghostty-vt with zig cc" | tee -a "$LOG_FILE"
  (
    cd "$GHOSTTY_DIR"
    line="$(rg '^zig ld -dynamic .*libghostty-vt' "$LOG_FILE" | tail -n 1)"
    dylib_out="$(printf '%s\n' "$line" | sed -n 's/.* -o \([^ ]*libghostty-vt[^ ]*\.dylib\).*/\1/p')"
    mapfile -t objects < <(
      printf '%s\n' "$line" |
        tr ' ' '\n' |
        rg '^(\.zig-cache|/Users/).*[.]o$'
    )
    mapfile -t archives < <(
      printf '%s\n' "$line" |
        tr ' ' '\n' |
        rg '^(\.zig-cache|/Users/).*[.]a$'
    )
    extracted=()
    remaining_archives=()
    extract_root="$GHOSTTY_DIR/.zig-cache/portal-archive-objects"
    rm -rf "$extract_root"
    mkdir -p "$extract_root"
    archive_index=0
    for archive in "${archives[@]}"; do
      case "$archive" in
        *libsimdutf.a|*libhighway.a|*libutfcpp.a)
          archive_dir="$extract_root/$archive_index"
          mkdir -p "$archive_dir"
          (cd "$archive_dir" && ar -x "$archive")
          chmod u+rw "$archive_dir"/*.o
          while IFS= read -r object; do
            extracted+=("$object")
          done < <(find "$archive_dir" -type f -name '*.o' | sort)
          archive_index=$((archive_index + 1))
          ;;
        *)
          remaining_archives+=("$archive")
          ;;
      esac
    done
    echo "fallback objects=${#objects[@]} extracted=${#extracted[@]} archives=${#remaining_archives[@]} out=$dylib_out"
    "$ZIG" cc \
      -target aarch64-macos.13.0 \
      -dynamiclib \
      -isysroot "$SDKROOT_PATH" \
      -install_name @rpath/libghostty-vt.dylib \
      -Wl,-headerpad_max_install_names \
      -Wl,-dead_strip \
      -o "$dylib_out" \
      "${objects[@]}" \
      "${extracted[@]}" \
      "${remaining_archives[@]}" \
      -lc++ \
      -lSystem
    mkdir -p "$INSTALL_DIR/lib" "$INSTALL_DIR/include"
    cp "$dylib_out" "$INSTALL_DIR/lib/libghostty-vt.dylib"
    rm -rf "$INSTALL_DIR/include/ghostty"
    cp -R "$GHOSTTY_DIR/include/ghostty" "$INSTALL_DIR/include/ghostty"
  ) >>"$LOG_FILE" 2>&1
  build_status=0
fi

if [[ $build_status -ne 0 ]]; then
  cat >&2 <<EOF
Failed to build libghostty-vt with Zig 0.15.2.
Log: $LOG_FILE
EOF
  sed -n '1,160p' "$LOG_FILE" >&2
  exit "$build_status"
fi

if [[ ! -f "$INSTALL_DIR/share/pkgconfig/libghostty-vt.pc" ]]; then
  mkdir -p "$INSTALL_DIR/share/pkgconfig"
  cat >"$INSTALL_DIR/share/pkgconfig/libghostty-vt.pc" <<EOF
prefix=$INSTALL_DIR
includedir=\${prefix}/include
libdir=\${prefix}/lib

Name: libghostty-vt
URL: https://github.com/ghostty-org/ghostty
Description: Ghostty VT library
Version: 0.1.0
Cflags: -I\${includedir}
Libs: -L\${libdir} -lghostty-vt
EOF
fi

install_name_tool -id @rpath/libghostty-vt.dylib "$INSTALL_DIR/lib/libghostty-vt.dylib"
find "$INSTALL_DIR" -maxdepth 4 -type f | sort
