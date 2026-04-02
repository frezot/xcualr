#!/usr/bin/env bash
set -euo pipefail

# XCUALR benchmark runner.
#
# Purpose:
#   Run a small matrix of exports for the bundled sample xcresult files and
#   write a human-readable summary to bench.md.
#
# Requirements:
#   - a built release binary at .build/release/xcualr
#   - sample xcresult bundles in examples/TestResults_*.xcresult
#
# Usage:
#   ./bench.sh
#   ./bench.sh /path/to/custom.xcresult ...

BIN=".build/release/xcualr"

OUT_MD="bench.md"
BENCH_ROOT="examples/bench"

if [ "$#" -gt 0 ]; then
  SAMPLES=("$@")
else
  SAMPLES=()
  for candidate in examples/TestResults_0.xcresult examples/TestResults_1.xcresult examples/TestResults_2.xcresult; do
    if [ -e "$candidate" ]; then
      SAMPLES+=("$candidate")
    fi
  done
fi

if [ "${#SAMPLES[@]}" -eq 0 ]; then
  printf 'No .xcresult bundles provided and no default examples found.\n' >&2
  exit 1
fi

init_tables() {
  local sample_label="$1"
  printf '\n## %s\n\n' "$sample_label"
  printf '| %-24s | %11s | %7s | %14s |\n' 'Mode' 'Export time' 'Files' 'Total size KB'
  printf '|-%-24s-|-%11s-|-%7s-|-%14s-|\n' '------------------------' '-----------' '-------' '--------------'
}

run_case() {
  local sample="$1"
  local mode_label="$2"
  local outdir="$3"
  shift 3

  local stdout_log stderr_log export_time files size_kb row
  stdout_log="$(mktemp /tmp/xcualr-bench-stdout.XXXXXX)"
  stderr_log="$(mktemp /tmp/xcualr-bench-stderr.XXXXXX)"

  if ! /usr/bin/time -p "$BIN" export "$sample" -o "$outdir" -f "$@" \
    >"$stdout_log" 2>"$stderr_log"; then
    cat "$stdout_log"
    cat "$stderr_log" >&2
    rm -f "$stdout_log" "$stderr_log"
    exit 1
  fi

  export_time="$(awk -F': ' '/Export time:/ {print $2}' "$stderr_log" | tail -n 1)"
  files="$(find "$outdir" -type f | wc -l | tr -d ' ')"
  size_kb="$(du -sk "$outdir" | awk '{print $1}')"
  printf '| %-24s | %11s | %7s | %14s |\n' "$mode_label" "$export_time" "$files" "$size_kb"

  rm -f "$stdout_log" "$stderr_log"
}

printf '' >"$OUT_MD"
mkdir -p "$BENCH_ROOT"
{
  for sample in "${SAMPLES[@]}"; do
    sample_label="$(basename "${sample%.xcresult}")"
    init_tables "$sample_label"
    run_case "$sample" '1. raw (heic as is)' "$BENCH_ROOT/${sample_label}-raw" --raw-attachments
    run_case "$sample" '2. lib default' "$BENCH_ROOT/${sample_label}-lib-default"
    run_case "$sample" '3. lib colors=32' "$BENCH_ROOT/${sample_label}-lib-32" --passed-step-image-palette-colors 32
    run_case "$sample" '4. lib colors=16' "$BENCH_ROOT/${sample_label}-lib-16" --passed-step-image-palette-colors 16
    run_case "$sample" '5. no-lib default' "$BENCH_ROOT/${sample_label}-no-lib-default" --no-libs
    run_case "$sample" '6. no-lib colors=32' "$BENCH_ROOT/${sample_label}-no-lib-32" --no-libs --passed-step-image-palette-colors 32
    run_case "$sample" '7. no-lib colors=16' "$BENCH_ROOT/${sample_label}-no-lib-16" --no-libs --passed-step-image-palette-colors 16
  done
} | tee "$OUT_MD"
