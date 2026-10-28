#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/avz-memory-fastpath.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

build() {
    output=$1
    source=$2
    shift 2
    "${CC:-clang}" -std=c11 -O3 -Wall -Wextra -pthread \
        -I "$root/Sources/ARM64VizNative/include" \
        "-DAVZ_MEMORY_SOURCE=\"$source\"" "$@" \
        "$root/scripts/native-memory-fastpath-harness.c" -o "$output"
}

current="$root/Sources/ARM64VizNative/ARM64VizGuestMemory.c"
case "${1:---check}" in
    --check|--ubsan|--asan|--tsan)
        flags=""
        case "${1:---check}" in
            --ubsan) flags="-O1 -g -fsanitize=undefined -fno-sanitize-recover=all" ;;
            --asan) flags="-O1 -g -fsanitize=address -fno-sanitize-recover=all" ;;
            --tsan) flags="-O1 -g -fsanitize=thread" ;;
        esac
        build "$work/current" "${2:-$current}" $flags
        "$work/current"
        ;;
    --benchmark)
        test "$#" -ge 2 || { echo "requires saved baseline C path" >&2; exit 2; }
        build "$work/baseline" "$2"
        build "$work/current" "$current"
        "$work/baseline"
        "$work/current"
        run=1
        while test "$run" -le "${RUNS:-6}"; do
            if test $((run % 2)) -eq 1; then order="baseline current"; else order="current baseline"; fi
            for version in $order; do
                echo "version=$version run=$run"
                "$work/$version" --benchmark "${ITERATIONS:-200000}" "${MODE:-}"
            done
            run=$((run + 1))
        done
        ;;
    *) echo "usage: sh $0 [--check|--ubsan|--asan|--tsan] [source.c] | --benchmark baseline.c" >&2; exit 2 ;;
esac
