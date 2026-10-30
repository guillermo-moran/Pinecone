#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
native="$root/Sources/ARM64VizNative"
case "${1:-}" in
    '') flags=-O2 ;;
    --ubsan) flags='-O1 -g -fsanitize=undefined -fno-sanitize-recover=all' ;;
    *) echo "usage: $0 [--ubsan]" >&2; exit 2 ;;
esac
test "$(uname -sm)" = 'Darwin arm64' || { echo 'Requires Darwin arm64' >&2; exit 2; }
work=$(mktemp -d "${TMPDIR:-/tmp}/pinecone-chain-contract.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
clang -std=c11 -Wall -Wextra -Werror -I "$native/include" \
    "$root/experiments/phase3/offsets.c" -o "$work/offsets"
"$work/offsets" > "$work/offsets.h"
cmp "$work/offsets.h" "$native/Assembly/offsets.h"
for source in ARM64VizBlockCache ARM64VizGuestMemory ARM64VizThreadedPrototype Assembly/gadget Assembly/memory; do
    name=$(basename "$source")
    clang -std=c11 $flags -DAG_ENABLE=1 -DAVZ_ASSEMBLY_EXECUTOR_ENABLE=1 \
        -DAVZ_THREADED_PROTOTYPE_ENABLE=1 -I "$native/include" \
        -c "$native/$source.c" -o "$work/$name.o"
done
clang -std=c11 $flags -Wall -Wextra -Werror -DAG_ENABLE=1 -I "$native/include" \
    -c "$root/experiments/phase3/chain.c" -o "$work/chain.o"
clang -arch arm64 -g -c "$native/Assembly/gadget_arm64.S" -o "$work/assembly.o"
clang -std=c11 $flags -DAG_ENABLE=1 -DAVZ_ASSEMBLY_EXECUTOR_ENABLE=1 \
    -DAVZ_THREADED_PROTOTYPE_ENABLE=1 -I "$native/include" \
    "$root/scripts/phase7-chain-integration-contract.c" "$work"/*.o -pthread -lm -o "$work/test"
# Safety timeout only; no timings or throughput measurements are collected.
perl -e 'alarm 30; exec @ARGV or die $!' "$work/test"
