#!/bin/sh
set -eu
if [ "$#" -ne 1 ]; then
  echo "usage: sh build-trace.sh NEW-OUTPUT-DIRECTORY" >&2
  exit 2
fi
src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir "$1"
out=$(CDPATH= cd -- "$1" && pwd)
case $(uname -s) in
  Linux) kind=-shared; suffix=so ;;
  Darwin) kind=-dynamiclib; suffix=dylib ;;
  *) echo 'unsupported host' >&2; exit 1 ;;
esac
"${CC:-cc}" -std=c11 -O2 -g -Wall -Wextra -Werror -fPIC "$kind" \
  "$src/trace.c" -pthread -o "$out/libpinecone-text-trace.$suffix"
cp "$src/trace.h" "$out/pinecone-text-trace.h"
printf '%s\n' "$out/libpinecone-text-trace.$suffix"
