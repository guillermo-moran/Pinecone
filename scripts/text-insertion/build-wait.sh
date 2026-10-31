#!/bin/sh
set -eu
if [ "$#" -ne 2 ]; then
  echo 'usage: sh build-wait.sh EXISTING-TRACE-RUNTIME NEW-OUTPUT' >&2
  exit 2
fi
src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
runtime=$(CDPATH= cd -- "$1" && pwd)
mkdir "$2"
out=$(CDPATH= cd -- "$2" && pwd)
cc -std=gnu11 -O2 -g -Wall -Wextra -Werror -Wshadow -fPIC -shared \
  $(pkg-config --cflags gtk4) -I"$src" "$src/trace-wait.c" \
  -Wl,--no-as-needed -lgtk-4 -Wl,--as-needed $(pkg-config --libs gtk4) \
  -ldl -L"$runtime" -lpinecone-text-trace \
  -Wl,-rpath,'$ORIGIN' -o "$out/libpinecone-text-wait.so"
sha256sum "$out/libpinecone-text-wait.so"
