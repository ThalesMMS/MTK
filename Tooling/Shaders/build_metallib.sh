#!/usr/bin/env bash

# build_metallib.sh
# Shared helper used by release packaging and CI to compile
# MTK/Sources/MTKCore/Resources/**/*.metal into
# MTK.metallib. By default the script remains permissive for headless
# builders; set METALLIB_STRICT=1 to treat missing inputs or tools as errors.

set -euo pipefail

INPUT_DIR=${1:-"$(cd -- "$(dirname "$0")"/../../Sources/MTKCore/Resources/Shaders && pwd)"}
OUTPUT_PATH=${2:-"$INPUT_DIR/MTK.metallib"}
SHADER_ROOT=${MTK_SHADER_ROOT:-"$(cd -- "$INPUT_DIR/.." && pwd)"}
STRICT=${METALLIB_STRICT:-0}

fail_or_skip() {
  local message="$1"
  if [[ "$STRICT" == "1" ]]; then
    echo "[build_metallib] ERROR: $message" >&2
    exit 1
  fi
  echo "[build_metallib] $message Skipping." >&2
  exit 0
}

if [[ ! -d "$SHADER_ROOT" ]]; then
  fail_or_skip "Shader root '$SHADER_ROOT' not found."
fi

if ! command -v xcrun >/dev/null 2>&1; then
  fail_or_skip "xcrun unavailable; cannot generate MTK.metallib."
fi

infer_sdk() {
  if [[ -n "${MTK_METAL_SDK:-}" ]]; then
    echo "$MTK_METAL_SDK"
    return
  fi

  local value
  for value in "${SDKROOT:-}" "${PLATFORM_NAME:-}" "${SDK_NAME:-}" "${EFFECTIVE_PLATFORM_NAME:-}"; do
    case "$value" in
      *iPhoneSimulator*|*iphonesimulator*) echo "iphonesimulator"; return ;;
      *iPhoneOS*|*iphoneos*) echo "iphoneos"; return ;;
      *MacOSX*|*macosx*) echo "macosx"; return ;;
    esac
  done

  echo "macosx"
}

deployment_target_for_sdk() {
  case "$1" in
    iphonesimulator|iphoneos)
      echo "${MTK_METAL_DEPLOYMENT_TARGET:-${IPHONEOS_DEPLOYMENT_TARGET:-17.0}}"
      ;;
    macosx)
      echo "${MTK_METAL_DEPLOYMENT_TARGET:-${MACOSX_DEPLOYMENT_TARGET:-14.0}}"
      ;;
    *)
      echo "${MTK_METAL_DEPLOYMENT_TARGET:-}"
      ;;
  esac
}

target_for_sdk() {
  if [[ -n "${MTK_METAL_TARGET:-}" ]]; then
    echo "$MTK_METAL_TARGET"
    return
  fi

  local deployment_target
  deployment_target=$(deployment_target_for_sdk "$1")
  case "$1" in
    iphonesimulator) echo "air64-apple-ios${deployment_target}-simulator" ;;
    iphoneos) echo "air64-apple-ios${deployment_target}" ;;
    macosx) echo "air64-apple-macosx${deployment_target}" ;;
    *) echo "" ;;
  esac
}

SDK=$(infer_sdk)
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

build_metallib_for_sdk() {
  local sdk="$1"
  local output_path="$2"
  local sdk_path
  local metalc
  local metallib_bin
  local metal_target
  local sdk_tmp
  local -a air_files=()

  sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path 2>/dev/null || true)
  metalc=$(xcrun --sdk "$sdk" --find metal 2>/dev/null || true)
  metallib_bin=$(xcrun --sdk "$sdk" --find metallib 2>/dev/null || true)
  metal_target=$(target_for_sdk "$sdk")

  if [[ -z "$metalc" || -z "$metallib_bin" ]]; then
    fail_or_skip "Metal toolchain for SDK '$sdk' not found; cannot generate $(basename "$output_path")."
  fi

  echo "[build_metallib] SDK=$sdk target=${metal_target:-default}"

  sdk_tmp="$TMPDIR/$sdk"
  mkdir -p "$sdk_tmp"

  while IFS= read -r metal_file; do
    [[ -z "$metal_file" ]] && continue
    local -a metal_args=()
    local base
    local air
    base=$(basename "$metal_file" .metal)
    air="$sdk_tmp/$base.air"
    if [[ -n "$metal_target" ]]; then
      metal_args+=("-target" "$metal_target")
    fi
    if [[ -n "$sdk_path" ]]; then
      "$metalc" "${metal_args[@]}" -isysroot "$sdk_path" -c "$metal_file" -o "$air"
    else
      "$metalc" "${metal_args[@]}" -c "$metal_file" -o "$air"
    fi
    air_files+=("$air")
  done < <(find "$SHADER_ROOT" -name '*.metal' -print | sort)

  if [[ ${#air_files[@]} -eq 0 ]]; then
    fail_or_skip "No .metal files found under '$INPUT_DIR'."
  fi

  mkdir -p "$(dirname "$output_path")"
  "$metallib_bin" -o "$output_path" "${air_files[@]}"
  echo "[build_metallib] Wrote $(basename "$output_path")"
}

if [[ "$SDK" == "all" ]]; then
  OUTPUT_DIR=$(dirname "$OUTPUT_PATH")
  build_metallib_for_sdk "macosx" "$OUTPUT_DIR/MTK.metallib"
  build_metallib_for_sdk "iphonesimulator" "$OUTPUT_DIR/MTK-iphonesimulator.metallib"
  build_metallib_for_sdk "iphoneos" "$OUTPUT_DIR/MTK-iphoneos.metallib"
else
  build_metallib_for_sdk "$SDK" "$OUTPUT_PATH"
fi
