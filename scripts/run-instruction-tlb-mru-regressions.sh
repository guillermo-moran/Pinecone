#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/pinecone-instruction-tlb.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
flags=-O3
case "${1:-}" in
    '') ;;
    --ubsan) flags='-O1 -g -fsanitize=undefined -fno-sanitize-recover=all' ;;
    --benchmark) ;;
    *) exit 2 ;;
esac
for version in 0 1; do
    clang -std=c11 $flags -DAVZ_INSTRUCTION_TLB_MRU=$version \
        -I "$root/Sources/ARM64VizNative/include" \
        "$root/scripts/instruction-tlb-mru-regression.c" -pthread -o "$work/$version"
    "$work/$version"
done
if test "${1:-}" = --benchmark; then
    run=0
    while test "$run" -lt "${RUNS:-7}"; do
        if test $((run % 2)) = 0; then order='0 1'; else order='1 0'; fi
        for version in $order; do
            echo "mru=$version run=$run"
            "$work/$version" --benchmark "${ITERATIONS:-2000000}"
        done
        run=$((run + 1))
    done
fi
