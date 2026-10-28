#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
case "$(uname -m)" in
    arm64|aarch64) ;;
    *) echo 'SKIP: static native references require an AArch64 host' >&2; exit 77 ;;
esac
mode=${1:-all}
case "$mode" in all|memory|fp|atomic|publication) ;; *) echo 'usage: run.sh [all|memory|fp|atomic|publication] [--ubsan|--asan]' >&2; exit 2 ;; esac
sanitizer=
case "${2:-}" in
    '') ;;
    --ubsan) sanitizer='-O1 -g -fsanitize=undefined -fno-sanitize-recover=all' ;;
    --asan) sanitizer='-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=all' ;;
    *) exit 2 ;;
esac
test "$#" -le 2 || exit 2
work=$(mktemp -d "${TMPDIR:-/tmp}/arm64viz-android-validation.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
fingerprint=$(shasum -a 256 "$root/Sources/ARM64VizNative/ARM64VizNative.c" \
    "$root/Sources/ARM64VizNative/ARM64VizBlockCache.c" "$root/Sources/ARM64VizNative/ARM64VizGuestMemory.c")
"${CC:-clang}" -std=c11 -O2 $sanitizer -pthread \
    -I "$root/Sources/ARM64VizNative/include" -I "$root/Sources/ARM64VizNative" \
    "$root/scripts/android-runtime-validation/regression.c" \
    "$root/scripts/android-runtime-validation/sequences.S" \
    "$root/Sources/ARM64VizNative/ARM64VizBlockCache.c" \
    "$root/Sources/ARM64VizNative/ARM64VizGuestMemory.c" -lm -o "$work/regression"
after=$(shasum -a 256 "$root/Sources/ARM64VizNative/ARM64VizNative.c" \
    "$root/Sources/ARM64VizNative/ARM64VizBlockCache.c" "$root/Sources/ARM64VizNative/ARM64VizGuestMemory.c")
test "$fingerprint" = "$after" || { echo 'RETRY: production sources changed during compilation' >&2; exit 3; }
printf '%s\n' "$fingerprint"
"$work/regression" "$mode"
