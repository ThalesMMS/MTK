#!/usr/bin/env bash

# verify_metallib.sh
# Quick sanity check that MTK.metallib exists in the Release build output.

set -euo pipefail

ROOT="${1:-.build}"
TARGET="MTK.metallib"

echo "[verify_metallib] Searching for $TARGET under '$ROOT'"

if [[ ! -d "$ROOT" ]]; then
  echo "[verify_metallib] Build directory '$ROOT' not found"
  exit 1
fi

found=0
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  found=1
  size=$(stat -f %z "$path" 2>/dev/null || stat -c %s "$path" 2>/dev/null || echo "0")
  echo "[verify_metallib] $path (${size} bytes)"
done < <(find "$ROOT" -name "$TARGET" -print)

if [[ $found -eq 0 ]]; then
  echo "[verify_metallib] ERROR: $TARGET not found"
  exit 1
fi

echo "[verify_metallib] Done"
