#!/usr/bin/env bash

# build_docs.sh
# Shared helper used by CI/CD to generate Swift DocC documentation
# for MTK package targets (MTKCore, MTKSceneKit, MTKUI).
# Designed to succeed even on headless builders.

set -euo pipefail

DRY_RUN=${MTK_DOCS_DRY_RUN:-false}

# Parse command-line flags first
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
done

# Restore positional arguments (handle empty array)
if [[ ${#POSITIONAL_ARGS[@]} -gt 0 ]]; then
  set -- "${POSITIONAL_ARGS[@]}"
else
  set --
fi

PACKAGE_ROOT=${1:-"$(cd -- "$(dirname "$0")/.." && pwd)"}
OUTPUT_DIR=${2:-"$PACKAGE_ROOT/docs"}

if [[ ! -d "$PACKAGE_ROOT" ]]; then
  echo "[build_docs] Package root '$PACKAGE_ROOT' not found. Skipping." >&2
  exit 0
fi

if [[ ! -f "$PACKAGE_ROOT/Package.swift" ]]; then
  echo "[build_docs] Package.swift not found at '$PACKAGE_ROOT'. Skipping." >&2
  exit 0
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "[build_docs] swift command unavailable. Skipping documentation generation." >&2
  exit 0
fi

# Check for swift-docc-plugin availability
if ! swift package --package-path "$PACKAGE_ROOT" plugin --list 2>/dev/null | grep -qi "Swift-DocC\|generate-documentation"; then
  echo "[build_docs] swift-docc-plugin not available. Skipping." >&2
  exit 0
fi

# Dry-run mode: verify tools and exit
if [[ "$DRY_RUN" == "true" ]]; then
  echo "[build_docs] Dry-run mode: All prerequisites satisfied."
  echo "[build_docs] Would build documentation for: MTKCore, MTKSceneKit, MTKUI"
  echo "[build_docs] Output directory: $OUTPUT_DIR"
  exit 0
fi

# List of targets to document
TARGETS=("MTKCore" "MTKSceneKit" "MTKUI")

echo "[build_docs] Building documentation for ${#TARGETS[@]} targets..."

# Clean output directory
if [[ -d "$OUTPUT_DIR" ]]; then
  rm -rf "$OUTPUT_DIR"
fi
mkdir -p "$OUTPUT_DIR"

# Build documentation for each target
for target in "${TARGETS[@]}"; do
  echo "[build_docs] Generating documentation for $target..."

  if ! swift package --package-path "$PACKAGE_ROOT" \
    --allow-writing-to-directory "$OUTPUT_DIR" \
    generate-documentation \
    --target "$target" \
    --output-path "$OUTPUT_DIR/$target.doccarchive" \
    --transform-for-static-hosting \
    --hosting-base-path "MTK/$target" 2>&1; then
    echo "[build_docs] Warning: Failed to generate documentation for $target." >&2
    continue
  fi

  if [[ -d "$OUTPUT_DIR/$target.doccarchive" ]]; then
    echo "[build_docs] OK: Wrote $target.doccarchive"
  else
    echo "[build_docs] Warning: $target.doccarchive not created." >&2
  fi
done

echo "[build_docs] Documentation build complete."
