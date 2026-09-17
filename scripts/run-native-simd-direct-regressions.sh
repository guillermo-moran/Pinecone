#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/arm64viz-simd-direct.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

# Optional baseline must be a pre-change copy of ARM64VizNative.c.
build() {
    output=$1
    shift
    clang -std=c11 -O2 \
        -I "$root/Sources/ARM64VizNative/include" \
        -I "$root/Sources/ARM64VizNative" "$@" \
        "$root/scripts/native-simd-direct-regression.c" \
        "$root/Sources/ARM64VizNative/ARM64VizBlockCache.c" \
        "$root/Sources/ARM64VizNative/ARM64VizGuestMemory.c" \
        -lm -o "$output"
}

build "$work/direct"
"$work/direct"
if [ "${1:-}" = "--benchmark" ]; then
    if [ "$#" -eq 2 ]; then
        build "$work/baseline" "-DAVZ_SIMD_NATIVE_SOURCE=\"$2\"" -DEXPECT_GENERIC_DISPATCHES=1
        "$work/baseline"
        echo "BASELINE"
        "$work/baseline" --benchmark
    fi
    echo "DIRECT"
    "$work/direct" --benchmark
elif [ "${1:-}" = "--sanitize" ] && [ "$#" -eq 1 ]; then
    build "$work/sanitized" -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer
    "$work/sanitized"
elif [ "${1:-}" = "--ubsan" ] && [ "$#" -eq 1 ]; then
    build "$work/ubsan" -O1 -fsanitize=undefined -fno-sanitize-recover=all
    "$work/ubsan"
elif [ "$#" -eq 0 ]; then
    if [ "$(uname -m)" = arm64 ]; then
        "$work/direct" --emit-memory > "$work/memory.txt"
        sh "$root/scripts/run-simd-memory-differential.sh" "$work/memory.txt"
        "$work/direct" --emit-vector > "$work/vector.txt"
        sh "$root/scripts/run-simd-differential.sh" "$work/vector.txt"
    else
        echo "SKIP hardware differential: requires ARM64 host"
    fi
else
    echo "usage: $0 [--sanitize|--ubsan|--benchmark [absolute-path-to-baseline.c]]" >&2
    exit 2
fi
