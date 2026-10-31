#!/bin/sh
set -eu
if [ "$#" -ne 1 ]; then
  echo 'usage: sh build-wordexp.sh NEW-OUTPUT' >&2
  exit 2
fi
src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir "$1"
out=$(realpath "$1")
cc -std=gnu11 -O2 -g -Wall -Wextra -Werror -Wshadow -fPIC -shared \
  "$src/trace-wordexp.c" -ldl -pthread -o "$out/libpinecone-wordexp-trace.so"
readelf -d "$out/libpinecone-wordexp-trace.so" >"$out/dependencies.txt"
test "$(grep -c NEEDED "$out/dependencies.txt")" = 1
grep -q 'NEEDED.*libc.musl-aarch64.so.1' "$out/dependencies.txt"
sha256sum "$out/libpinecone-wordexp-trace.so"
