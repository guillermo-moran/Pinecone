#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <native-decode-audit.txt>" >&2
    exit 2
fi

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
audit_file=$1
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/arm64viz-simd-differential.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

awk -v mode=assembly -f "$project_dir/scripts/generate-simd-differential.awk" \
    "$audit_file" > "$work_dir/simd-differential-cases.S"
awk -v mode=include -f "$project_dir/scripts/generate-simd-differential.awk" \
    "$audit_file" > "$work_dir/simd-differential-cases.inc"

clang -std=c11 -O2 \
    -I "$project_dir/Sources/ARM64VizNative/include" \
    -I "$work_dir" \
    "$project_dir/scripts/simd-differential-main.c" \
    "$project_dir/Sources/ARM64VizNative/ARM64VizNative.c" \
    "$project_dir/Sources/ARM64VizNative/ARM64VizBlockCache.c" \
    "$project_dir/Sources/ARM64VizNative/ARM64VizGuestMemory.c" \
    "$work_dir/simd-differential-cases.S" \
    -lm \
    -o "$work_dir/simd-differential"

"$work_dir/simd-differential"
