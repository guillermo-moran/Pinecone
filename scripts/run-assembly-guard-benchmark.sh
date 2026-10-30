#!/bin/sh
# Explicit coalesced experiment versus uncoalesced control, not production entry.
# Native-host only. Does not inspect, suspend, launch or modify any Simulator.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
native="$root/Sources/ARM64VizNative"
build_only=0
if test "${1:-}" = --build-only; then
    build_only=1
    shift
    test -n "${AG_BUILD_DIR:-}" || {
        echo '--build-only requires AG_BUILD_DIR to retain the binary' >&2
        exit 2
    }
fi
test "$(uname -sm)" = 'Darwin arm64' || {
    echo 'Requires Darwin arm64 host' >&2
    exit 2
}
if test -n "${AG_BUILD_DIR:-}"; then
    work=$AG_BUILD_DIR
    mkdir -p "$work"
else
    work=$(mktemp -d "${TMPDIR:-/tmp}/pinecone-assembly-guard.XXXXXX")
    trap 'rm -rf "$work"' EXIT HUP INT TERM
fi
clang --version >&2
shasum -a 256 "$root/scripts/assembly-guard-benchmark.c" "$0" \
    "$root/experiments/phase3/reference.c" "$root/experiments/phase3/offsets.c" \
    "$native/Assembly/"*.[ch] "$native/Assembly/gadget_arm64.S" \
    "$native/ARM64VizNative.c" "$native/ARM64VizBlockCache.c" \
    "$native/ARM64VizGuestMemory.c" "$native/ARM64VizGuestMemoryInternal.h" \
    "$native/ARM64VizThreadedPrototype.c" "$native/include/"*.h >&2
clang -std=c11 -I "$native/include" "$root/experiments/phase3/offsets.c" -o "$work/offsets"
"$work/offsets" > "$work/offsets.h"
cmp "$work/offsets.h" "$native/Assembly/offsets.h"
for source in ARM64VizBlockCache ARM64VizGuestMemory ARM64VizThreadedPrototype Assembly/gadget Assembly/memory; do
    name=$(basename "$source")
    clang -std=c11 -O3 -DAG_ENABLE=1 -DAVZ_ASSEMBLY_EXECUTOR_ENABLE=1 \
        -DAVZ_THREADED_PROTOTYPE_ENABLE=1 -I "$native/include" \
        -c "$native/$source.c" -o "$work/$name.o"
done
clang -std=c11 -O3 -DAG_ENABLE=1 -DAVZ_ASSEMBLY_EXECUTOR_ENABLE=1 \
    -DAVZ_THREADED_PROTOTYPE_ENABLE=1 -I "$native/include" \
    -c "$root/experiments/phase3/reference.c" -o "$work/reference.o"
clang -arch arm64 -g -c "$native/Assembly/gadget_arm64.S" -o "$work/assembly.o"
clang -std=c11 -O3 -Wall -Wextra -Werror -DAG_ENABLE=1 \
    -DAVZ_ASSEMBLY_EXECUTOR_ENABLE=1 -DAVZ_THREADED_PROTOTYPE_ENABLE=1 \
    -I "$native/include" "$root/scripts/assembly-guard-benchmark.c" \
    "$work/ARM64VizBlockCache.o" "$work/ARM64VizGuestMemory.o" \
    "$work/ARM64VizThreadedPrototype.o" "$work/gadget.o" "$work/memory.o" \
    "$work/reference.o" "$work/assembly.o" -pthread -lm -o "$work/assembly-guard-benchmark"
xcrun llvm-objdump --disassemble --no-show-raw-insn "$work/gadget.o" > "$work/entries.txt"
shasum -a 256 "$work/assembly-guard-benchmark" >&2
echo "guard benchmark binary: $work/assembly-guard-benchmark" >&2
if test "$build_only" = 0; then
    perl -e 'alarm 180; exec @ARGV or die $!' "$work/assembly-guard-benchmark" "$@"
fi
