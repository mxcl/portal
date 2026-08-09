#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${PORTAL_REAL_ZIG:-}" ]]; then
  echo "PORTAL_REAL_ZIG is required" >&2
  exit 2
fi

run_zig() {
  if [[ -n "${PORTAL_ZIG_TRACE:-}" ]]; then
    printf '%q' "$PORTAL_REAL_ZIG" >>"$PORTAL_ZIG_TRACE"
    printf ' %q' "$@" >>"$PORTAL_ZIG_TRACE"
    printf '\n' >>"$PORTAL_ZIG_TRACE"
  fi
  exec "$PORTAL_REAL_ZIG" "$@"
}

sdk="${SDKROOT:-}"
if [[ -z "$sdk" ]]; then
  sdk="$(xcrun --show-sdk-path)"
fi

cmd="${1:-}"
case "$cmd" in
  build-exe|build-lib|build-obj|test|test-obj|run)
    has_target=0
    has_sysroot=0
    darwin_target=0
    expect_target_value=0
    for arg in "$@"; do
      if [[ "$expect_target_value" == 1 ]]; then
        [[ "$arg" == *macos* ]] && darwin_target=1
        expect_target_value=0
      fi
      case "$arg" in
        -target|--target)
          has_target=1
          expect_target_value=1
          ;;
        -target=*|--target=*|-Dtarget=*)
          has_target=1
          [[ "$arg" == *macos* ]] && darwin_target=1
          ;;
        --sysroot)
          has_sysroot=1
          ;;
      esac
    done

    normalized=()
    for arg in "${@:2}"; do
      case "$arg" in
        "$sdk/usr/lib")
          normalized+=("/usr/lib")
          ;;
        "$sdk/usr/include")
          normalized+=("/usr/include")
          ;;
        "$sdk/System/Library/Frameworks")
          normalized+=("/System/Library/Frameworks")
          ;;
        *)
          normalized+=("$arg")
          ;;
      esac
    done

    system_lib=()
    if [[ "$cmd" == "build-exe" || "$cmd" == "build-lib" || "$cmd" == "run" || "$cmd" == "test" ]]; then
      system_lib=(-lSystem)
    fi

    with_system_lib=()
    inserted_system_lib=0
    for arg in "${normalized[@]}"; do
      if [[ "$inserted_system_lib" == 0 && "$arg" == --listen* ]]; then
        with_system_lib+=("${system_lib[@]}")
        inserted_system_lib=1
      fi
      with_system_lib+=("$arg")
    done
    if [[ "$inserted_system_lib" == 0 ]]; then
      with_system_lib+=("${system_lib[@]}")
    fi

    if [[ "$has_target" == 0 ]]; then
      if [[ "$has_sysroot" == 1 ]]; then
        run_zig "$cmd" -target aarch64-macos.15.0 "${with_system_lib[@]}"
      else
        run_zig "$cmd" -target aarch64-macos.15.0 --sysroot "$sdk" "${with_system_lib[@]}"
      fi
    fi

    if [[ "$darwin_target" == 1 && "$has_sysroot" == 0 ]]; then
      run_zig "$cmd" --sysroot "$sdk" "${with_system_lib[@]}"
    fi
    ;;
esac

run_zig "$@"
