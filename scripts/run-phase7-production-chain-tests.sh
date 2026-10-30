#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
native="$root/Sources/ARM64VizNative"
mode=
flags=-O2
sanitizer=
profile=
build_only=
usage() {
    echo "usage: $0 [--build-only] [--ubsan|--asan] [--case=NAME] | --benchmark | --profile" >&2
    echo 'cases: budgets invalidation helpers selection semantic-superblock legacy two-owners timers entry-translation' >&2
    echo '       bounded-budgets bounded-timers bounded-helpers bounded-invalidation bounded-two-owners bounded-selection' >&2
    echo '       bounded-helper-timers bounded-page-publication bounded-allocation-failure' >&2
    exit 2
}
for arg in "$@"; do
    case "$arg" in
        --build-only) test -z "$build_only" || usage; build_only=1 ;;
        --ubsan|--asan)
            test -z "$sanitizer" && test "$mode" != --benchmark || usage
            sanitizer=$arg
            case "$arg" in
                --ubsan) flags='-O1 -g -fsanitize=undefined -fno-sanitize-recover=all' ;;
                --asan) flags='-O1 -g -fsanitize=address -fno-omit-frame-pointer' ;;
            esac ;;
        --benchmark|--profile)
            test -z "$mode" && test -z "$sanitizer" || usage
            mode=--benchmark; flags=-O3
            if test "$arg" = --profile; then profile=-DAG_BOUNDARY_PROFILE=1; fi ;;
        --case=budgets|--case=invalidation|--case=helpers|--case=selection|--case=semantic-superblock|--case=legacy|--case=two-owners|--case=timers|--case=entry-translation|--case=bounded-budgets|--case=bounded-timers|--case=bounded-helpers|--case=bounded-invalidation|--case=bounded-two-owners|--case=bounded-selection|--case=bounded-helper-timers|--case=bounded-page-publication|--case=bounded-allocation-failure)
            test -z "$mode" || usage
            mode=$arg ;;
        *) usage ;;
    esac
done
test_hooks=-DAG_PRODUCTION_TEST_HOOKS=1
if test "$mode" = --benchmark; then test_hooks=; fi
test "$(uname -sm)" = 'Darwin arm64' || { echo 'Requires Darwin arm64' >&2; exit 2; }
cc=${CC:-clang}
sdk=${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}
test -d "$sdk" || { echo "SDK not found: $sdk" >&2; exit 2; }
printf 'compiler: %s\nSDK: %s\n' "$cc" "$sdk"
"$cc" --version
work=$(mktemp -d "${TMPDIR:-/tmp}/pinecone-production-chain.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
"$cc" -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror -I "$native/include" \
    "$root/experiments/phase3/offsets.c" -o "$work/offsets"
"$work/offsets" > "$work/offsets.h"
cmp "$work/offsets.h" "$native/Assembly/offsets.h"
for source in ARM64VizBlockCache ARM64VizGuestMemory ARM64VizThreadedPrototype Assembly/gadget Assembly/memory Assembly/service_chain; do
    name=$(basename "$source")
    entry_hook=
    if test -n "$test_hooks" && test "$source" = Assembly/service_chain; then
        entry_hook='-Dag_enter=test_service_enter -Dmalloc=test_service_malloc'
    fi
    "$cc" -isysroot "$sdk" -std=c11 $flags $profile -DAG_ENABLE=1 -DAG_SERVICE_CHAIN_ENABLE=1 \
        -DAVZ_ASSEMBLY_EXECUTOR_ENABLE=1 -DAVZ_THREADED_PROTOTYPE_ENABLE=1 \
        $entry_hook -I "$native/include" -c "$native/$source.c" -o "$work/$name.o"
done
"$cc" -isysroot "$sdk" -arch arm64 -g -DAG_SERVICE_CHAIN_ENABLE=1 \
    -c "$native/Assembly/gadget_arm64.S" -o "$work/assembly.o"
"$cc" -isysroot "$sdk" -std=c11 $flags $profile -DAG_ENABLE=1 -DAG_SERVICE_CHAIN_ENABLE=1 \
    -DAVZ_ASSEMBLY_EXECUTOR_ENABLE=1 -DAVZ_THREADED_PROTOTYPE_ENABLE=1 \
    $test_hooks -I "$native/include" "$root/scripts/phase7-production-chain-test.c" \
    "$work"/*.o -pthread -lm -o "$work/test"
if test -n "$build_only"; then
    echo 'PASS production chain build only (no tests or timings executed)'
    exit 0
fi
# Safety deadline. Only the explicit --benchmark mode collects CPU timings.
perl -e 'printf STDERR "EXEC production chain pid=%d (60-second timeout)\n", $$; alarm 60; exec @ARGV or die $!' "$work/test" $mode
