#!/bin/sh
set -eu
if [ "$#" -ne 2 ]; then
  echo 'usage: sh test-wordexp.sh TRACER-DIRECTORY NEW-OUTPUT' >&2
  exit 2
fi
src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
runtime=$(realpath "$1")
mkdir "$2"
out=$(realpath "$2")
cc -std=c11 -O2 -Wall -Wextra -Werror "$src/test-wordexp.c" -o "$out/test-wordexp"
for enabled in 0 1; do
  PINECONE_WORDEXP_TRACE="$enabled" PINECONE_WORDEXP_TRACE_EXE=test-wordexp \
    LD_PRELOAD="$runtime/libpinecone-wordexp-trace.so" \
    "$out/test-wordexp" >"$out/test-$enabled.log" 2>&1
done
test "$(grep -c '^PCWORD1 call ' "$out/test-1.log")" = 11
grep -q 'records=11 dropped=0' "$out/test-1.log"
if grep -q PCWORD1 "$out/test-0.log"; then exit 1; fi
if grep -q 'private payload' "$out/test-1.log"; then exit 1; fi
PINECONE_WORDEXP_TRACE=1 LD_PRELOAD="$runtime/libpinecone-wordexp-trace.so" \
  "$out/test-wordexp" >"$out/wrong-executable.log" 2>&1
if grep -q PCWORD1 "$out/wrong-executable.log"; then exit 1; fi
printf 'libc-only wordexp tracer forwarding/gating passed: %s\n' "$out"
