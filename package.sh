#!/usr/bin/env bash
set -euo pipefail

# XCUALR binary packager.
#
# Purpose:
#   Build release binaries for arm64 and x86_64 and place them separately
#   under output/.
#
# Requirements:
#   - SwiftPM release build support
#
# Usage:
#   ./package.sh

OUT_DIR="output"
ARM_BUILD_DIR=".build/arm64/release"
X86_BUILD_DIR=".build/x86_64/release"
ARM_BIN="$ARM_BUILD_DIR/xcualr"
X86_BIN="$X86_BUILD_DIR/xcualr"

mkdir -p "$OUT_DIR"

swift build -c release --triple arm64-apple-macosx --build-path .build/arm64
cp "$ARM_BIN" "$OUT_DIR/xcualr"

swift build -c release --triple x86_64-apple-macosx --build-path .build/x86_64
cp "$X86_BIN" "$OUT_DIR/xcualr-x86_64"

printf 'Wrote:\n'
printf '  %s\n' "$OUT_DIR/xcualr"
printf '  %s\n' "$OUT_DIR/xcualr-x86_64"
