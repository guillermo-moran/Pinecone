#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
native="$root/Sources/ARM64VizNative"
work=$(mktemp -d "${TMPDIR:-/tmp}/pinecone-assembly-runtime.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
case "${1:-}" in
    '') flags=-O3 ;;
    --ubsan) flags='-O1 -g -fsanitize=undefined -fno-sanitize-recover=all' ;;
    --sanitize) flags='-O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all' ;;
    *) echo "usage: $0 [--ubsan|--sanitize]" >&2; exit 2 ;;
esac
test "$(uname -sm)" = 'Darwin arm64'
clang -std=c11 -I "$native/include" "$root/experiments/phase3/offsets.c" -o "$work/offsets"
"$work/offsets" > "$work/offsets.h"
cmp "$work/offsets.h" "$native/Assembly/offsets.h"
for source in ARM64VizBlockCache ARM64VizGuestMemory ARM64VizThreadedPrototype Assembly/gadget Assembly/memory; do
    name=$(basename "$source")
    clang -std=c11 $flags -DAG_ENABLE=1 -DAVZ_ASSEMBLY_EXECUTOR_ENABLE=1 \
        -DAVZ_THREADED_PROTOTYPE_ENABLE=1 -I "$native/include" \
        -c "$native/$source.c" -o "$work/$name.o"
done
clang -arch arm64 -g -c "$native/Assembly/gadget_arm64.S" -o "$work/assembly.o"
for fixture in threaded-runtime-regression threaded-memory-continuation-regression; do
    clang -std=c11 $flags -DAVZ_TEST_ASSEMBLY=1 -DAG_ENABLE=1 \
        -DAVZ_ASSEMBLY_EXECUTOR_ENABLE=1 -DAVZ_THREADED_PROTOTYPE_ENABLE=1 \
        -I "$native/include" "$root/scripts/$fixture.c" "$work"/*.o \
        -pthread -lm -o "$work/$fixture"
    perl -e 'alarm 240; exec @ARGV or die $!' "$work/$fixture"
done
