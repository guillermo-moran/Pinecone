#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
src="$root/experiments/phase3"
native="$root/Sources/ARM64VizNative"
mode=${1:---test}
case "$mode" in
    --test|--benchmark|--benchmark-memory|--benchmark-entry|--benchmark-chain|--benchmark-hot|--benchmark-address|--benchmark-pair|--benchmark-indirect|--benchmark-conditional) flags=-O3 ;;
    --ubsan) flags='-O1 -g -fsanitize=undefined -fno-sanitize-recover=all' ;;
    --asan) flags='-O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all' ;;
    *) echo "usage: $0 [--test|--ubsan|--asan|--benchmark|--benchmark-memory|--benchmark-entry|--benchmark-chain|--benchmark-hot|--benchmark-address|--benchmark-pair|--benchmark-indirect|--benchmark-conditional]" >&2; exit 2 ;;
esac
test "$(uname -sm)" = 'Darwin arm64' || { echo 'Requires Darwin arm64 host' >&2; exit 2; }
if test -n "${AG_BUILD_DIR:-}"; then
    work=$AG_BUILD_DIR
    mkdir -p "$work"
else
    work=$(mktemp -d "${TMPDIR:-/tmp}/pinecone-gadget.XXXXXX")
    trap 'rm -rf "$work"' EXIT HUP INT TERM
fi
clang --version >&2
shasum -a 256 "$src"/*.c "$src"/*.h "$src"/*.S "$src/run.sh" \
    "$native/Assembly"/*.c "$native/Assembly"/*.h "$native/Assembly"/*.S \
    "$native/ARM64VizNative.c" "$native/ARM64VizThreadedPrototype.c" >&2
clang -std=c11 -Wall -Wextra -Werror -I "$native/include" "$src/offsets.c" -o "$work/offsets"
"$work/offsets" > "$work/offsets.h"
cmp "$work/offsets.h" "$native/Assembly/offsets.h"
clang -std=c11 $flags -DAVZ_THREADED_PROTOTYPE_ENABLE=1 -I "$native/include" \
    -c "$src/reference.c" -o "$work/ARM64VizNative.o"
for unit in ARM64VizBlockCache ARM64VizGuestMemory ARM64VizThreadedPrototype; do
    clang -std=c11 $flags -DAVZ_THREADED_PROTOTYPE_ENABLE=1 -I "$native/include" \
        -c "$native/$unit.c" -o "$work/$unit.o"
done
for unit in gadget chain chain_tests memory memory_tests harness; do
    clang -std=c11 $flags -Wall -Wextra -Werror -DAG_ENABLE=1 \
        -I "$native/include" -I "$work" -c "$src/$unit.c" -o "$work/$unit.o"
done
clang -arch arm64 -g -I "$work" -c "$src/gadget_arm64.S" -o "$work/gadget_arm64.o"
clang -arch arm64 -g -I "$work" -c "$src/abi_probe.S" -o "$work/abi_probe.o"
xcrun llvm-objdump --disassemble --reloc --no-show-raw-insn "$work/gadget_arm64.o" > "$work/dispatch.txt"
if grep -E '[[:space:]]blr[[:space:]]|[[:space:],]x18([[:space:],]|$)' "$work/dispatch.txt"; then
    echo 'Unexpected call or reserved x18 use in gadget code' >&2; exit 1
fi
# Only the two terminal memory helpers may call C. Hot dispatch stays call-free.
test "$(grep -Ec '[[:space:]]bl[[:space:]]' "$work/dispatch.txt")" = 2
test "$(grep -Ec 'ARM64_RELOC_BRANCH26[[:space:]]+_ag_memory_slow' "$work/dispatch.txt")" = 1
test "$(grep -Ec 'ARM64_RELOC_BRANCH26[[:space:]]+_ag_memory_commit' "$work/dispatch.txt")" = 1
grep -Eq '[[:space:]]br[[:space:]]+x9' "$work/dispatch.txt"
xcrun dwarfdump --eh-frame "$work/gadget_arm64.o" > "$work/unwind.txt"
grep -q FDE "$work/unwind.txt"
link() {
    clang $flags "$work/harness.o" "$work/gadget.o" "$work/chain.o" "$work/chain_tests.o" "$work/memory.o" "$work/memory_tests.o" "$work/gadget_arm64.o" "$work/abi_probe.o" \
        "$work/ARM64VizNative.o" "$work/ARM64VizBlockCache.o" "$work/ARM64VizGuestMemory.o" \
        "$work/ARM64VizThreadedPrototype.o" -pthread -lm -o "$work/test"
    entry_address=$(nm -n "$work/test" | awk '$NF == "_ag_enter" { print $1 }')
    test -n "$entry_address"
    test "$((0x$entry_address % 64))" -eq 0
}
link
if test "$mode" = --benchmark || test "$mode" = --benchmark-memory || test "$mode" = --benchmark-entry || test "$mode" = --benchmark-chain || test "$mode" = --benchmark-hot || test "$mode" = --benchmark-address || test "$mode" = --benchmark-pair || test "$mode" = --benchmark-indirect || test "$mode" = --benchmark-conditional; then
    perl -e 'alarm 300; exec @ARGV or die $!' "$work/test" "$mode"
else
    perl -e 'alarm 180; exec @ARGV or die $!' "$work/test"
    cp "$work/test" "$work/test-enabled"
    clang -std=c11 $flags -Wall -Wextra -Werror -I "$native/include" \
        -c "$src/gadget.c" -o "$work/gadget.o"
    link
    "$work/test" --disabled
fi
