#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
native="$root/Sources/ARM64VizNative"
work=$(mktemp -d "${TMPDIR:-/tmp}/pinecone-assembly-fp.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
case "${1:-}" in
    '') flags=-O3 ;;
    --ubsan) flags='-O1 -g -fsanitize=undefined -fno-sanitize-recover=all' ;;
    *) echo "usage: $0 [--ubsan]" >&2; exit 2 ;;
esac
test "$(uname -sm)" = 'Darwin arm64'
fixture=${PINECONE_ASSEMBLY_FIXTURE:-assembly-fp-moves-regression}
case "$fixture" in assembly-fp-moves-regression|assembly-simd-logic-regression) ;; *) exit 2 ;; esac
for source in ARM64VizBlockCache ARM64VizGuestMemory ARM64VizThreadedPrototype Assembly/gadget Assembly/aot Assembly/memory; do
    name=$(basename "$source")
    clang -std=c11 $flags -DAG_ENABLE=1 -DAVZ_ASSEMBLY_EXECUTOR_ENABLE=1 \
        -DAVZ_THREADED_PROTOTYPE_ENABLE=1 -I "$native/include" \
        -c "$native/$source.c" -o "$work/$name.o"
done
clang -arch arm64 -g -c "$native/Assembly/gadget_arm64.S" -o "$work/assembly.o"
clang -std=c11 $flags -DAG_ENABLE=1 -DAVZ_ASSEMBLY_EXECUTOR_ENABLE=1 \
    -DAVZ_THREADED_PROTOTYPE_ENABLE=1 -I "$native/include" \
    "$root/scripts/$fixture.c" "$work"/*.o \
    -pthread -lm -o "$work/fp-moves"
perl -e 'alarm 120; exec @ARGV or die $!' "$work/fp-moves"
