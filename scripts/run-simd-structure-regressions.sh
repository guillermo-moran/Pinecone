#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/pinecone-simd-structures.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

clang -std=c11 -O2 -I "$root/Sources/ARM64VizNative/include" \
    "$root/scripts/simd-structure-cases.c" \
    "$root/Sources/ARM64VizNative/ARM64VizNative.c" \
    "$root/Sources/ARM64VizNative/ARM64VizBlockCache.c" \
    "$root/Sources/ARM64VizNative/ARM64VizGuestMemory.c" \
    -o "$work/cases"
"$work/cases" > "$work/cases.txt"
sh "$root/scripts/run-simd-memory-differential.sh" "$work/cases.txt"
"$work/cases" broadcasts > "$work/broadcasts.txt"
sh "$root/scripts/run-simd-differential.sh" "$work/broadcasts.txt"
