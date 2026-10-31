#!/bin/sh
set -eu
if [ "$#" -ne 2 ]; then
  echo 'usage: sh test-commit.sh NEW-OUTPUT-DIRECTORY TRACE-RUNTIME-DIRECTORY' >&2
  exit 2
fi
src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
runtime=$(CDPATH= cd -- "$2" && pwd)
mkdir "$1"
out=$(CDPATH= cd -- "$1" && pwd)
cc -std=c11 -O2 -Wall -Wextra -Werror -Wshadow -fPIC -shared -DPC_COMMIT_LIBRARY \
  $(pkg-config --cflags gtk4) -I"$src" "$src/test-commit.c" \
  $(pkg-config --libs gtk4) -o "$out/libspelling-1.so.fixture"
cc -std=c11 -O2 -Wall -Wextra -Werror -Wshadow $(pkg-config --cflags gtk4) \
  -I"$src" "$src/test-commit.c" "$out/libspelling-1.so.fixture" \
  $(pkg-config --libs gtk4) -L"$runtime" -lpinecone-text-trace \
  -Wl,-rpath,"$runtime" -o "$out/test-commit"
PINECONE_TEXT_INSERTION_TRACE=0 LD_PRELOAD="$runtime/libpinecone-text-commit.so" \
  "$out/test-commit" >"$out/disabled.log" 2>&1
PINECONE_TEXT_INSERTION_TRACE=1 LD_PRELOAD="$runtime/libpinecone-text-commit.so" \
  "$out/test-commit" >"$out/enabled.log" 2>&1
python3 "$src/analyze.py" "$out/enabled.log" >"$out/report.json"
test "$(grep -c 'name=spelling.commit.' "$out/enabled.log")" = 5
printf 'Commit callback forwarding/lifetime tests passed: %s\n' "$out"
