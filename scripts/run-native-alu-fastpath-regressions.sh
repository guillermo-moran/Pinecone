#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mode=${1:-}
reference=${AVZ_NATIVE_REFERENCE_PATH:-}
case "$mode" in
    ''|--syntax-only|--ubsan) test "$#" -le 1 ;;
    --benchmark)
        test "$#" -le 2
        reference=${2:-$reference}
        test -n "$reference" || {
            echo "benchmark requires a frozen pre-edit ARM64VizNative.c" >&2
            exit 2
        }
        ;;
    *) echo "usage: $0 [--syntax-only|--ubsan|--benchmark /absolute/before.c]" >&2; exit 2 ;;
esac
if test -n "$reference"; then
    case "$reference" in /*) ;; *) echo "reference must be an absolute path" >&2; exit 2 ;; esac
    test -f "$reference"
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/arm64viz-alu.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
# Freeze each selected translation unit for this invocation; never reconstruct
# a baseline from HEAD because the working source may include unrelated edits.
cp "$root/Sources/ARM64VizNative/ARM64VizNative.c" "$work/current.c"
if test -n "$reference"; then cp "$reference" "$work/baseline.c"; fi

run_bounded() {
    perl -e 'alarm 180; exec @ARGV; die "exec failed: $!\n";' -- "$@"
}

build() {
    version=$1
    shift
    run_bounded "${CC:-clang}" -std=c11 -O3 \
        -DAVZ_ASSEMBLY_EXECUTOR_ENABLE=0 -DAVZ_THREADED_PROTOTYPE_ENABLE=0 \
        -I "$root/Sources/ARM64VizNative/include" \
        -I "$root/Sources/ARM64VizNative" \
        "-DAVZ_NATIVE_REFERENCE_PATH=\"$work/$version.c\"" "$@" \
        "$root/scripts/native-alu-fastpath-regression.c" \
        "$root/Sources/ARM64VizNative/ARM64VizBlockCache.c" \
        "$root/Sources/ARM64VizNative/ARM64VizGuestMemory.c" \
        -lm -o "$work/$version"
}

case "$mode" in
    --syntax-only)
        build current -fsyntax-only
        if test -n "$reference"; then build baseline -fsyntax-only; fi
        ;;
    --ubsan)
        build current -O1 -g -fsanitize=undefined -fno-sanitize-recover=all
        run_bounded "$work/current"
        ;;
    --benchmark)
        if cmp -s "$work/current.c" "$work/baseline.c"; then
            echo "reference and current source are identical; no before/after comparison" >&2
            exit 2
        fi
        echo "Mapped C executor, -O3, 64 dependent ALU instructions per call, 20000 repeats per cell."
        echo "Timings include dispatch, entry/exit, PC reset, and counter accumulation."
        echo "ns_per_step is wall time; thread_cpu_ns_per_step is CLOCK_THREAD_CPUTIME_ID."
        echo "Same live headers/cache/memory dependencies; only the native C source is frozen."
        echo "No speedup threshold or isolated instruction-cost claim. Review source diff for attribution."
        run_bounded "${CC:-clang}" --version
        shasum -a 256 "$work/baseline.c" "$work/current.c" \
            "$root/scripts/native-alu-fastpath-regression.c" \
            "$root/Sources/ARM64VizNative/ARM64VizBlockCache.c" \
            "$root/Sources/ARM64VizNative/ARM64VizGuestMemory.c"
        build baseline
        build current
        run_bounded "$work/baseline"
        run_bounded "$work/current"
        # Alternate order to reduce systematic warmup/order bias, not host noise.
        for run in 1 2 3 4 5 6; do
            if test $((run % 2)) -eq 1; then order="baseline current"; else order="current baseline"; fi
            for version in $order; do
                echo "version=$version run=$run"
                run_bounded "$work/$version" --benchmark
            done
        done
        ;;
    '')
        build current
        run_bounded "$work/current"
        ;;
esac
