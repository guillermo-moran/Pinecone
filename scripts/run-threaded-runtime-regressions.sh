#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/pinecone-threaded-runtime.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
case "${1:-}" in
    '') flags=-O3 ;;
    --ubsan) flags='-O1 -fsanitize=undefined -fno-sanitize-recover=all' ;;
    --benchmark|--dispatch-benchmark) flags=-O3 ;;
    *) echo "usage: $0 [--ubsan|--benchmark|--dispatch-benchmark]" >&2; exit 2 ;;
esac
clang -std=c11 $flags -DAVZ_THREADED_PROTOTYPE_ENABLE=1 \
    "-DAVZ_RUNTIME_NATIVE_SOURCE=\"${AVZ_RUNTIME_NATIVE_SOURCE:-$root/Sources/ARM64VizNative/ARM64VizNative.c}\"" \
    -I "$root/Sources/ARM64VizNative/include" -I "$root/Sources/ARM64VizNative" \
    "$root/scripts/threaded-runtime-regression.c" \
    "$root/Sources/ARM64VizNative/ARM64VizBlockCache.c" \
    "$root/Sources/ARM64VizNative/ARM64VizGuestMemory.c" \
    "$root/Sources/ARM64VizNative/ARM64VizThreadedPrototype.c" -lm -o "$work/test"
if test "${1:-}" = --benchmark || test "${1:-}" = --dispatch-benchmark; then
    "$work/test" "$1"
else
    "$work/test"
fi
