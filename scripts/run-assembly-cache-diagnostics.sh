#!/bin/sh
# Isolated tests only: no Simulator, Swift build, benchmark or existing fixture.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
native="$root/Sources/ARM64VizNative"
work=$(mktemp -d "${TMPDIR:-/tmp}/pinecone-cache-diagnostics.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
case "${1:-}" in
    '') flags='-O2' ;;
    --ubsan) flags='-O1 -g -fsanitize=undefined -fno-sanitize-recover=all' ;;
    *) echo "usage: $0 [--ubsan]" >&2; exit 2 ;;
esac
test "$(uname -sm)" = 'Darwin arm64'
for source in ARM64VizNative ARM64VizGuestMemory Assembly/gadget Assembly/memory; do
    name=$(basename "$source")
    clang -std=c11 $flags -DAG_ENABLE=1 -DAVZ_ASSEMBLY_EXECUTOR_ENABLE=1 \
        -DAVZ_THREADED_PROTOTYPE_ENABLE=0 -I "$native/include" \
        -c "$native/$source.c" -o "$work/$name.o"
done
clang -arch arm64 -g -c "$native/Assembly/gadget_arm64.S" -o "$work/assembly.o"
for budget in 4194304 65536; do
for enabled in 0 1; do
    clang -std=c11 $flags -DAG_ENABLE=1 -DAVZ_ASSEMBLY_EXECUTOR_ENABLE=1 \
        -DAVZ_THREADED_PROTOTYPE_ENABLE=0 -DAVZ_ASSEMBLY_CACHE_DIAGNOSTICS="$enabled" \
        -DAVZ_ASSEMBLY_CACHE_BYTE_BUDGET="$budget" \
        -I "$native/include" "$root/scripts/assembly-cache-diagnostics-test.c" \
        "$work"/*.o -pthread -lm -o "$work/test-$enabled"
    perl -e 'alarm 60; exec @ARGV or die $!' "$work/test-$enabled"
done
done
# Inspect the real cache object, without the test clock/creation wrappers.
clang -std=c11 -O2 -DAVZ_ASSEMBLY_EXECUTOR_ENABLE=1 -DAVZ_THREADED_PROTOTYPE_ENABLE=0 \
    -I "$native/include" -c "$native/ARM64VizBlockCache.c" -o "$work/cache-off.o"
if nm -u "$work/cache-off.o" | grep -E 'clock_gettime|mach_absolute_time'; then
    echo 'disabled diagnostics unexpectedly reference a clock' >&2
    exit 1
fi
# Exercise both feature guards and coexistence with the older threaded cache.
clang -std=c11 -O2 -DAVZ_ASSEMBLY_EXECUTOR_ENABLE=0 -DAVZ_ASSEMBLY_CACHE_DIAGNOSTICS=1 \
    -DAVZ_THREADED_PROTOTYPE_ENABLE=0 -I "$native/include" \
    -fsyntax-only "$native/ARM64VizBlockCache.c"
clang -std=c11 -O2 -DAVZ_ASSEMBLY_EXECUTOR_ENABLE=1 -DAVZ_ASSEMBLY_CACHE_DIAGNOSTICS=1 \
    -DAVZ_THREADED_PROTOTYPE_ENABLE=1 -DAVZ_THREADED_CACHE_DIAGNOSTICS=1 \
    -I "$native/include" -fsyntax-only "$native/ARM64VizBlockCache.c"
echo 'feature guards and disabled clock-symbol check: PASS'
