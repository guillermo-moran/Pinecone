#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
native="$root/Sources/ARM64VizNative"
case "${1:-}" in
    '') flags=-O2 ;;
    --ubsan) flags='-O1 -g -fsanitize=undefined -fno-sanitize-recover=all' ;;
    *) echo "usage: $0 [--ubsan]" >&2; exit 2 ;;
esac
test "$(uname -sm)" = 'Darwin arm64'
work=$(mktemp -d "${TMPDIR:-/tmp}/pinecone-dispatch.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
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
clang -std=c11 $flags -DAG_ENABLE=1 -DAVZ_ASSEMBLY_EXECUTOR_ENABLE=1 \
    -DAVZ_THREADED_PROTOTYPE_ENABLE=1 -I "$native/include" \
    "$root/scripts/assembly-dispatch-regression.c" "$work"/*.o -pthread -lm -o "$work/test"
perl -e 'alarm 60; exec @ARGV or die $!' "$work/test"
# The ordinary disabled build must still compile without the private assembly API.
clang -std=c11 $flags -I "$native/include" -fsyntax-only "$native/ARM64VizNative.c"
