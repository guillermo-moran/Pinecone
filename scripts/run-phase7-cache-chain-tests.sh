#!/bin/sh
# Standalone native correctness tests only; no Simulator/build/benchmark.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
native="$root/Sources/ARM64VizNative"
case "${1:-}" in
    '') flags=-O2 ;;
    --ubsan) flags='-O1 -g -fsanitize=undefined -fno-sanitize-recover=all' ;;
    --asan) flags='-O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer' ;;
    *) echo "usage: $0 [--ubsan|--asan]" >&2; exit 2 ;;
esac
test "$#" -le 1
test "$(uname -sm)" = 'Darwin arm64'
# Select a matching compiler/runtime explicitly; never silently drop sanitizers.
cc=${CC:-clang}
sdk=${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}
test -d "$sdk" || { echo "SDK not found: $sdk" >&2; exit 2; }
printf 'compiler: %s\nSDK: %s\n' "$cc" "$sdk"
"$cc" --version
work=$(mktemp -d "${TMPDIR:-/tmp}/pinecone-cache-chain.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
for source in ARM64VizNative ARM64VizGuestMemory Assembly/gadget Assembly/memory Assembly/service_chain; do
    name=$(basename "$source")
    "$cc" -isysroot "$sdk" -std=c11 $flags -DAG_ENABLE=1 -DAG_SERVICE_CHAIN_ENABLE=1 \
        -DAVZ_ASSEMBLY_EXECUTOR_ENABLE=1 -DAVZ_THREADED_PROTOTYPE_ENABLE=0 \
        -I "$native/include" -c "$native/$source.c" -o "$work/$name.o"
done
"$cc" -isysroot "$sdk" -arch arm64 -g -DAG_SERVICE_CHAIN_ENABLE=1 \
    -c "$native/Assembly/gadget_arm64.S" -o "$work/assembly.o"
"$cc" -isysroot "$sdk" -std=c11 $flags -Wall -Wextra -Werror -DAG_ENABLE=1 -DAG_SERVICE_CHAIN_ENABLE=1 \
    -DAVZ_ASSEMBLY_EXECUTOR_ENABLE=1 -DAVZ_THREADED_PROTOTYPE_ENABLE=0 \
    -I "$native/include" "$root/scripts/phase7-cache-chain-test.c" \
    "$work"/*.o -pthread -lm -o "$work/test"
perl -e 'alarm 60; exec @ARGV or die $!' "$work/test"
"$cc" -isysroot "$sdk" -std=c11 -O2 -DAVZ_ASSEMBLY_EXECUTOR_ENABLE=1 -DAVZ_THREADED_PROTOTYPE_ENABLE=0 \
    -I "$native/include" -c "$native/ARM64VizBlockCache.c" -o "$work/cache-off.o"
if nm -u "$work/cache-off.o" | grep 'ag_service_chain'; then
    echo 'default-off cache unexpectedly references service runtime' >&2; exit 1
fi
"$cc" -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror -DAVZ_ASSEMBLY_EXECUTOR_ENABLE=0 \
    -DAG_SERVICE_CHAIN_ENABLE=1 -I "$native/include" \
    -fsyntax-only "$native/ARM64VizBlockCache.c"
echo 'default-off service-symbol and disabled-assembly checks: PASS'
