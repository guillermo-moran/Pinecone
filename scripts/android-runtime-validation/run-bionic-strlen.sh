#!/bin/sh
# The source must be supplied explicitly; this script never downloads code.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
test "$#" -eq 1 || { echo 'usage: run-bionic-strlen.sh /absolute/path/to/pinned/strlen.S' >&2; exit 2; }
case "$1" in /*) ;; *) echo 'absolute source path required' >&2; exit 2 ;; esac
case "$(uname -m)" in arm64|aarch64) ;; *) exit 77 ;; esac
expected=6e540fc330389c765d107f7e4a33f4b224c9d353
actual=$(git hash-object -- "$1")
test "$actual" = "$expected" || {
    echo "source mismatch: expected Git blob $expected, got $actual" >&2; exit 2;
}
work=$(mktemp -d "${TMPDIR:-/tmp}/arm64viz-bionic-validation.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
"${CC:-clang}" -x assembler-with-cpp \
    -I "$root/scripts/android-runtime-validation/bionic-include" -c "$1" -o "$work/strlen.o"
"${CC:-clang}" -std=c11 -O2 -pthread -DAVZ_BIONIC_REFERENCE=1 \
    -I "$root/Sources/ARM64VizNative/include" -I "$root/Sources/ARM64VizNative" \
    "$root/scripts/android-runtime-validation/regression.c" \
    "$root/scripts/android-runtime-validation/sequences.S" "$work/strlen.o" \
    "$root/Sources/ARM64VizNative/ARM64VizBlockCache.c" \
    "$root/Sources/ARM64VizNative/ARM64VizGuestMemory.c" -lm -o "$work/regression"
echo "source_git_blob=$actual"
"$work/regression" bionic
