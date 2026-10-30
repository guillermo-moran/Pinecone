#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
native="$root/Sources/ARM64VizNative"
enabled=1
service_flags=-DAG_SERVICE_CHAIN_ENABLE=1
case "${1:-}" in
    '') flags=-O2 ;;
    --ubsan) flags='-O1 -g -fsanitize=undefined -fno-sanitize-recover=all' ;;
    --disabled) flags=-O2; service_flags='' ;;
    --assembly-disabled) flags=-O2; enabled=0 ;;
    *) echo "usage: $0 [--ubsan|--disabled|--assembly-disabled]" >&2; exit 2 ;;
esac
test "$#" -le 1 || exit 2
test "$(uname -sm)" = 'Darwin arm64' || { echo 'Requires Darwin arm64' >&2; exit 2; }
work=$(mktemp -d "${TMPDIR:-/tmp}/pinecone-bounded-service.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
clang -std=c11 -Wall -Wextra -Werror -I "$native/include" \
    "$root/experiments/phase3/offsets.c" -o "$work/offsets"
"$work/offsets" > "$work/offsets.h"
cmp "$work/offsets.h" "$native/Assembly/offsets.h"
for source in ARM64VizNative ARM64VizBlockCache ARM64VizGuestMemory ARM64VizThreadedPrototype Assembly/gadget Assembly/memory Assembly/service_chain; do
    name=$(basename "$source")
    warnings=''
    allocation_flags=''
    case "$source" in Assembly/*) warnings='-Wall -Wextra -Werror' ;; esac
    case "$source" in Assembly/service_chain) allocation_flags='-Dmalloc=ag_bounded_test_malloc' ;; esac
    clang -std=c11 $flags $warnings $service_flags $allocation_flags -DAG_ENABLE="$enabled" -DAVZ_ASSEMBLY_EXECUTOR_ENABLE="$enabled" \
        -DAVZ_THREADED_PROTOTYPE_ENABLE=1 -I "$native/include" \
        -c "$native/$source.c" -o "$work/$name.o"
done
clang -arch arm64 -g $service_flags -c "$native/Assembly/gadget_arm64.S" -o "$work/assembly.o"
clang -arch arm64 -g -I "$native/Assembly" -c "$root/experiments/phase3/abi_probe.S" -o "$work/abi.o"
clang -std=c11 $flags $service_flags -Wall -Wextra -Werror -DAG_ENABLE="$enabled" -DAG_BOUNDED_ALLOC_TEST=1 -I "$native/include" \
    "$root/scripts/phase7-bounded-service-test.c" "$work"/*.o -pthread -lm -o "$work/test"
perl -e 'alarm 30; exec @ARGV or die $!' "$work/test"
