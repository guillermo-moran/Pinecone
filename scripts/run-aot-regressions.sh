#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
native="$root/Sources/ARM64VizNative"
case "${1:-}" in
    '') flags=-O3 ;;
    --ubsan) flags='-O1 -g -fsanitize=undefined -fno-sanitize-recover=all' ;;
    --sanitize) flags='-O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all' ;;
    *) echo "usage: $0 [--ubsan|--sanitize]" >&2; exit 2 ;;
esac
test "$(uname -sm)" = 'Darwin arm64'
work=$(mktemp -d "${TMPDIR:-/tmp}/pinecone-aot.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
generated="$native/Assembly/aot_generated.inc"
if test -n "${PINECONE_AOT_CORPUS:-}"; then
    generated="$work/generated.inc"
    python3 "$root/scripts/generate-aot.py" "$PINECONE_AOT_CORPUS" "$generated" \
        --max-blocks 10000 --seed "$root/scripts/aot-smoke-blocks.json"
fi
for source in ARM64VizBlockCache ARM64VizGuestMemory ARM64VizThreadedPrototype Assembly/gadget Assembly/aot Assembly/memory; do
    name=$(basename "$source")
    clang -std=c11 $flags -DAG_ENABLE=1 -DAVZ_ASSEMBLY_EXECUTOR_ENABLE=1 \
        -DAVZ_THREADED_PROTOTYPE_ENABLE=1 -I "$native/include" \
        "-DAG_AOT_GENERATED_INCLUDE=\"$generated\"" \
        -c "$native/$source.c" -o "$work/$name.o"
done
clang -arch arm64 -g -c "$native/Assembly/gadget_arm64.S" -o "$work/assembly.o"
clang -std=c11 $flags -DAG_ENABLE=1 -DAVZ_ASSEMBLY_EXECUTOR_ENABLE=1 \
    -DAVZ_THREADED_PROTOTYPE_ENABLE=1 -I "$native/include" \
    "-DAG_AOT_GENERATED_INCLUDE=\"$generated\"" \
    "$root/scripts/aot-regression.c" "$work"/*.o -pthread -lm -o "$work/test"
perl -e 'alarm 120; exec @ARGV or die $!' "$work/test"
