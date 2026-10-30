#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cc=${CC:-clang}
mode=${1:---test}
case "$mode" in
    --test|--benchmark|--sanitize|--ubsan|--verify) ;;
    *) echo "usage: $0 [--test|--benchmark|--sanitize|--ubsan|--verify]" >&2; exit 2 ;;
esac
work=$(mktemp -d "${TMPDIR:-/tmp}/arm64viz-threaded-prototype.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

# Freeze only the small C reference and headers, never a SwiftPM tree. Supply an
# existing captured directory to make different runs use the same reference.
source=${AVZ_TP_REFERENCE_DIR:-/tmp/pinecone-four-performance-baseline.l5K1sW/ARM64VizNative}
test -f "$source/ARM64VizNative.c" || {
    echo "frozen reference missing: set AVZ_TP_REFERENCE_DIR explicitly" >&2; exit 2;
}
mkdir "$work/reference"
cp "$source/ARM64VizNative.c" "$source/ARM64VizBlockCache.c" \
    "$source/ARM64VizGuestMemory.c" "$source/ARM64VizGuestMemoryInternal.h" "$work/reference/"
cp -R "$source/include" "$work/reference/include"
native="$work/reference"
cp "$root/Sources/ARM64VizNative/include/ARM64VizThreadedPrototype.h" "$native/include/"
prototype="$root/Sources/ARM64VizNative/ARM64VizThreadedPrototype.c"
harness="$root/scripts/threaded-prototype-harness.c"
"$cc" --version
uname -sm
shasum -a 256 "$native/ARM64VizNative.c" "$native/ARM64VizBlockCache.c" \
    "$native/ARM64VizGuestMemory.c" "$native/ARM64VizGuestMemoryInternal.h" \
    "$native/include/ARM64VizNative.h" "$native/include/ARM64VizThreadedPrototype.h" \
    "$prototype" "$harness" "$root/scripts/run-threaded-prototype.sh"
shasum -a 256 "$source/ARM64VizThreadedPrototype.c" "$source/include/ARM64VizThreadedPrototype.h"

compile_prototype() {
    "$cc" -std=c11 -Wall -Wextra -Werror \
        -I "$native/include" -I "$root/Sources/ARM64VizNative/include" \
        "$@" "$prototype"
}

verify() {
    compile_prototype -O0 -fno-optimize-sibling-calls -DAVZ_THREADED_PROTOTYPE_ENABLE=1 \
        -S -emit-llvm -o "$work/prototype.ll"
    tails=$(awk '/musttail call void %/ { n++ } END { print n+0 }' "$work/prototype.ll")
    test "$tails" -eq 50 || { echo "expected 50 mandatory tail sites, got $tails" >&2; exit 1; }
    compile_prototype -O3 -fno-optimize-sibling-calls -DAVZ_THREADED_PROTOTYPE_ENABLE=1 \
        -S -o "$work/prototype.s"
    # Verify actual AArch64/x86-64 handler bodies, not just a source annotation.
    awk '
      /^_?tp_(nop|add32|sub32|adds32|subs32|add64|sub64|adds64|subs64|move|movk|branch|link|bcond|zero|nonzero|((reg|ext|adc)(32|64)_(add|sub|adds|subs))|((and|orr|eor|ands)(32|64))):/ {
        active=1; tail=0; handlers++
      }
      active && /^[[:space:]]+(bl|blr|call|callq)[[:space:]]/ { bad=1 }
      active && /^[[:space:]]+(br[[:space:]]+x[0-9]+|jmpq?[[:space:]]+\*)/ { tail=1 }
      active && /[.]cfi_endproc/ { if (!tail) bad=1; active=0 }
      END { if (handlers != 48 || bad) { print "tail machine-code verification FAILED: handlers=" handlers; exit 1 }
            print "machine code: 48 register handlers, each indirect tail branch, zero ordinary calls" }
    ' "$work/prototype.s"
    awk '
      /^_?tp_(load|store):/ { active=1; handlers++; helper=0; returning=0; tail=0 }
      active && /[[:space:]](br[[:space:]]+x[0-9]+|jmpq?[[:space:]]+\*)/ { tail=1 }
      active && /[[:space:]](bl|callq?)[[:space:]]+_?avz_native_fast_memory_(read|write)/ { helper=1 }
      active && /^[[:space:]]+ret/ { returning=1 }
      active && /[.]cfi_endproc/ { if (!helper || !returning || !tail) bad=1; active=0 }
      END { if (handlers != 2 || bad) { print "memory continuation verification FAILED"; exit 1 }
            print "machine code: 2 memory handlers, hot-RAM tail successors and terminal helper exits" }
    ' "$work/prototype.s"
    if compile_prototype -O2 -DAVZ_THREADED_PROTOTYPE_ENABLE=1 \
        -DAVZ_THREADED_PROTOTYPE_HAS_MUSTTAIL=0 -c -o "$work/rejected.o" \
        >"$work/rejected.log" 2>&1; then
        echo "unsupported compiler unexpectedly accepted" >&2; exit 1
    fi
    grep -q 'requires compiler-enforced musttail; no fallback' "$work/rejected.log"
    echo "LLVM IR: $tails musttail sites at -O0; unavailable-musttail opt-in rejected"
    if test -n "${AVZ_TP_EMIT_DIR:-}"; then
        mkdir -p "$AVZ_TP_EMIT_DIR"
        cp "$work/prototype.ll" "$work/prototype.s" "$work/rejected.log" "$AVZ_TP_EMIT_DIR/"
    fi
}

verify
if test "$mode" = --verify; then exit 0; fi

flags="-O3"
if test "$mode" = --sanitize; then
    flags="-O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all"
elif test "$mode" = --ubsan; then
    flags="-O1 -g -fsanitize=undefined -fno-sanitize-recover=all"
fi
echo "reference=$source cflags=$flags mode=$mode"
for unit in ARM64VizNative ARM64VizBlockCache ARM64VizGuestMemory; do
    # flags is deliberately split into compiler arguments.
    "$cc" -std=c11 $flags -I "$native/include" -c "$native/$unit.c" -o "$work/$unit.o"
done
"$cc" -std=c11 $flags -Wall -Wextra -Werror \
    -I "$native/include" -I "$root/Sources/ARM64VizNative/include" \
    -c "$harness" -o "$work/harness.o"

build_and_run() {
    variant=$1
    shift
    compile_prototype $flags "$@" -c -o "$work/prototype.o"
    "$cc" $flags "$work/harness.o" "$work/prototype.o" \
        "$work/ARM64VizNative.o" "$work/ARM64VizBlockCache.o" \
        "$work/ARM64VizGuestMemory.o" -lm -o "$work/harness"
    echo "variant=$variant"
    case "$variant" in
        disabled) set -- --disabled ;;
        benchmark) set -- --benchmark ;;
        *) set -- ;;
    esac
    if test "$mode" = --sanitize; then
        # Some Apple ASan runtimes deadlock in initialization before main.
        # alarm survives exec and kills this process, not unrelated jobs.
        perl -e 'alarm 60; exec @ARGV or die $!' "$work/harness" "$@"
    else
        "$work/harness" "$@"
    fi
}

if test "$mode" = --benchmark; then
    build_and_run benchmark -DAVZ_THREADED_PROTOTYPE_ENABLE=1
else
    build_and_run enabled -DAVZ_THREADED_PROTOTYPE_ENABLE=1
    build_and_run disabled -DAVZ_THREADED_PROTOTYPE_HAS_MUSTTAIL=0
    if test "$mode" = --test; then
        build_and_run unoptimized-musttail -O0 -fno-optimize-sibling-calls \
            -DAVZ_THREADED_PROTOTYPE_ENABLE=1
    fi
fi
