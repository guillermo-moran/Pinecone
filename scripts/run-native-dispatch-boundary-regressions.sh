#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/arm64viz-boundary.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

build() {
    output=$1
    shift
    clang -std=c11 -O3 \
        -I "$root/Sources/ARM64VizNative/include" \
        -I "$root/Sources/ARM64VizNative" "$@" \
        "$root/scripts/native-dispatch-boundary-regression.c" \
        "$root/Sources/ARM64VizNative/ARM64VizBlockCache.c" \
        "$root/Sources/ARM64VizNative/ARM64VizGuestMemory.c" \
        -lm -o "$output"
}

case "${1:-}" in
    "")
        build "$work/current"
        "$work/current"
        ;;
    --ubsan)
        build "$work/ubsan" -O1 -fsanitize=undefined -fno-sanitize-recover=all
        "$work/ubsan"
        ;;
    --benchmark)
        test "$#" -eq 2 || { echo "benchmark requires absolute baseline C path" >&2; exit 2; }
        build "$work/baseline" "-DAVZ_BOUNDARY_NATIVE_SOURCE=\"$2\""
        build "$work/current"
        # Alternate order so a warming or busy host does not always favor one build.
        for run in 1 2 3 4 5 6; do
            if test $((run % 2)) -eq 1; then order="baseline current"; else order="current baseline"; fi
            for version in $order; do
                echo "version=$version run=$run"
                "$work/$version" --benchmark
            done
        done
        ;;
    *) echo "usage: $0 [--ubsan|--benchmark absolute-baseline-C-path]" >&2; exit 2 ;;
esac
