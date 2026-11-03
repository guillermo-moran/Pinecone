#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
native="$root/Sources/ARM64VizNative"
test "$(uname -sm)" = 'Darwin arm64'
work=$(mktemp -d "${TMPDIR:-/tmp}/pinecone-chain-proofs.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
flags=-O3
case "${1:-}" in
    '') ;;
    --ubsan) flags='-O1 -g -fsanitize=undefined -fno-sanitize-recover=all' ;;
    *) echo "usage: $0 [--ubsan]" >&2; exit 2 ;;
esac
for source in ARM64VizBlockCache ARM64VizGuestMemory ARM64VizThreadedPrototype Assembly/gadget Assembly/memory Assembly/service_chain; do
    name=$(basename "$source")
    entry_hook=
    if test "$source" = Assembly/service_chain; then
        entry_hook="-Dag_enter=proof_benchmark_enter -DAG_SERVICE_DEDUP_PAGE_PROOFS=${PINECONE_BENCHMARK_DEDUP_PAGE_PROOFS:-1}"
    fi
    clang -std=c11 $flags -DAG_ENABLE=1 -DAG_SERVICE_CHAIN_ENABLE=1 \
        -DAVZ_ASSEMBLY_EXECUTOR_ENABLE=1 -DAVZ_THREADED_PROTOTYPE_ENABLE=1 \
        $entry_hook -I "$native/include" -c "$native/$source.c" -o "$work/$name.o"
done
clang -arch arm64 -DAG_SERVICE_CHAIN_ENABLE=1 -c "$native/Assembly/gadget_arm64.S" -o "$work/assembly.o"
clang -std=c11 $flags -DAG_ENABLE=1 -DAG_SERVICE_CHAIN_ENABLE=1 \
    -DAVZ_ASSEMBLY_EXECUTOR_ENABLE=1 -DAVZ_THREADED_PROTOTYPE_ENABLE=1 \
    -I "$native/include" "$root/scripts/assembly-chain-proof-benchmark.c" \
    "$work"/*.o -pthread -lm -o "$work/test"
perl -e 'alarm 60; exec @ARGV or die $!' "$work/test"
