#!/usr/bin/env bash

# check_metallib_freshness.sh
# Fails when a checked-in metallib no longer matches the .metal sources next to
# it.
#
# The metallibs are binaries committed to the repository, and they are the
# libraries the tests and the app actually run — ShaderLibraryLoader loads them
# by name and has no fallback that compiles from source. Nothing rebuilds them,
# so a change to a shader has no effect, and no test can see it, until somebody
# runs build_metallib.sh. In #1679 that gap lasted sixteen days: the DVR
# windowing rewrite landed on 26 Jul, the metallibs were rebuilt on 27 Jul for
# an unrelated MPR change, and four rendering goldens that had been "passing"
# the whole time failed the moment the tests met the shader they were written
# for.
#
# All three slices are checked, not just the one the test suite loads. macOS is
# what `swift test` runs; iphoneos is what ships. A rebuild that writes only one
# of them leaves the others describing an older shader, which is the same defect
# one platform over — and the one nobody would be running tests against.
#
# The Metal frontend is deterministic: two builds of the same sources on the
# same toolchain are byte-identical, which is what makes this comparison
# possible. Across toolchains it is not, so a machine whose compiler differs
# from the one that produced a committed library reports the mismatch and moves
# on rather than failing work it cannot judge.
#
# Usage: MTK/Tooling/CI/check_metallib_freshness.sh [package-root]

set -euo pipefail

PACKAGE_ROOT=${1:-"$(cd -- "$(dirname "$0")"/../.. && pwd)"}
SHADER_DIR="$PACKAGE_ROOT/Sources/MTKCore/Resources/Shaders"
RESOURCE_DIR="$PACKAGE_ROOT/Sources/MTKCore/Resources"

# sdk:filename, in the order ShaderLibraryLoader prefers them per platform.
SLICES=(
    "macosx:MTK.metallib"
    "iphonesimulator:MTK-iphonesimulator.metallib"
    "iphoneos:MTK-iphoneos.metallib"
)

if ! command -v xcrun >/dev/null 2>&1; then
    echo "[metallib-freshness] xcrun unavailable; skipping."
    exit 0
fi

compiler_id() { # reads stdin, prints the metalfe-NNN identifier
    grep -oE 'metalfe-[0-9.]+' | sort -u | head -1
}

REBUILT=$(mktemp -t mtk-metallib)
trap 'rm -f "$REBUILT"' EXIT

stale=()
checked=()

for slice in "${SLICES[@]}"; do
    sdk="${slice%%:*}"
    filename="${slice#*:}"
    metallib="$RESOURCE_DIR/$filename"

    if [[ ! -f "$metallib" ]]; then
        echo "[metallib-freshness] ERROR: $filename is missing from Sources/MTKCore/Resources." >&2
        exit 1
    fi

    local_compiler=$(xcrun --sdk "$sdk" metal --version 2>/dev/null | compiler_id || true)
    if [[ -z "$local_compiler" ]]; then
        echo "[metallib-freshness] No Metal toolchain for the $sdk SDK; $filename not checked."
        continue
    fi

    committed_compiler=$(strings -a "$metallib" | compiler_id || true)
    if [[ -z "$committed_compiler" || "$committed_compiler" != "$local_compiler" ]]; then
        echo "[metallib-freshness] $filename was built by '${committed_compiler:-unknown}'," \
             "this machine has '$local_compiler'. Byte comparison is only meaningful within one" \
             "toolchain, so $filename is not checked."
        continue
    fi

    MTK_METAL_SDK="$sdk" METALLIB_STRICT=1 \
        "$PACKAGE_ROOT/Tooling/Shaders/build_metallib.sh" "$SHADER_DIR" "$REBUILT" >/dev/null

    if cmp -s "$REBUILT" "$metallib"; then
        checked+=("$filename")
    else
        stale+=("$filename")
    fi
done

if [[ ${#stale[@]} -gt 0 ]]; then
    cat >&2 <<EOF
[metallib-freshness] ERROR: ${stale[*]} does not match Sources/MTKCore/Resources/**/*.metal.

A shader was changed without rebuilding the bundled library, so the tests and
the app are still running the previous one. Rebuild all three slices and commit
them together — rebuilding one leaves the others stale:

    MTK_METAL_SDK=all MTK/Tooling/Shaders/build_metallib.sh \\
        MTK/Sources/MTKCore/Resources/Shaders \\
        MTK/Sources/MTKCore/Resources/MTK.metallib

Then re-run the MTK suite: a rendering golden that moves here is the shader
change becoming visible, not a new regression.
EOF
    exit 1
fi

if [[ ${#checked[@]} -eq 0 ]]; then
    echo "[metallib-freshness] No slice could be checked on this machine."
    exit 0
fi

echo "[metallib-freshness] ${checked[*]} match their sources."
