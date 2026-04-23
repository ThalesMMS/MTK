#!/usr/bin/env bash

# build_metallib.sh
# Shared helper used by MTKShaderPlugin and CI to compile
# MTK/Sources/MTKCore/Resources/Shaders/*.metal into
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

METALC=$(xcrun --find metal 2>/dev/null || true)
METALLIB_BIN=$(xcrun --find metallib 2>/dev/null || true)

if [[ -z "$METALC" || -z "$METALLIB_BIN" ]]; then
  fail_or_skip "Metal toolchain not found; cannot generate MTK.metallib."
fi

SDK=${MTK_METAL_SDK:-macosx}
SDK_PATH=$(xcrun --sdk "$SDK" --show-sdk-path 2>/dev/null || true)

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

AIR_FILES=()
while IFS= read -r metal_file; do
  [[ -z "$metal_file" ]] && continue
  base=$(basename "$metal_file" .metal)
  air="$TMPDIR/$base.air"
  if [[ -n "$SDK_PATH" ]]; then
    "$METALC" -isysroot "$SDK_PATH" -c "$metal_file" -o "$air"
  else
    "$METALC" -c "$metal_file" -o "$air"
  fi
  AIR_FILES+=("$air")
done < <(find "$SHADER_ROOT" -name '*.metal' -print | sort)

if [[ ${#AIR_FILES[@]} -eq 0 ]]; then
  fail_or_skip "No .metal files found under '$INPUT_DIR'."
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"
"$METALLIB_BIN" -o "$OUTPUT_PATH" "${AIR_FILES[@]}"
echo "[build_metallib] Wrote $(basename "$OUTPUT_PATH")"
