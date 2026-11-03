#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
frameworks=${1:?usage: run-virgl-metal-smoke.sh FRAMEWORK_DIRECTORY [--ubsan | --simulator DEVICE_UUID]}
frameworks=$(CDPATH= cd -- "$frameworks" && pwd)
flags=-O2
simulator=
case "${2:-}" in
    '') ;;
    --ubsan) flags='-O1 -g -fsanitize=undefined -fno-sanitize-recover=all' ;;
    --simulator) simulator=${3:?--simulator requires DEVICE_UUID} ;;
    *) exit 2 ;;
esac
work=$(mktemp -d "${TMPDIR:-/tmp}/pinecone-virgl-smoke.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
if [ -n "$simulator" ]; then
    xcrun --sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator \
        -std=c11 $flags -Wall -Wextra -Werror -I "$root/Sources/ARM64VizNative/include" \
        "$root/scripts/graphics/virgl-metal-smoke.c" "$root/Sources/ARM64VizNative/ARM64VizVirGL.m" \
        -pthread -framework Foundation -Wl,-rpath,"$frameworks" -o "$work/smoke"
    codesign --force --sign - "$work/smoke"
    xcrun simctl spawn "$simulator" "$work/smoke" "$frameworks"
else
    clang -std=c11 $flags -Wall -Wextra -Werror -I "$root/Sources/ARM64VizNative/include" \
        "$root/scripts/graphics/virgl-metal-smoke.c" "$root/Sources/ARM64VizNative/ARM64VizVirGL.m" \
        -pthread -framework Foundation -Wl,-rpath,"$frameworks" -o "$work/smoke"
    "$work/smoke" "$frameworks"
fi
