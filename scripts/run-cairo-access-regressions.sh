#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCHED_LIBDIR="${1:?usage: run-cairo-access-regressions.sh PATCHED_LIBDIR [STOCK_LIBDIR]}"
STOCK_LIBDIR="${2:-/usr/lib}"
WORK="$(mktemp -d /tmp/pinecone-cairo-access.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
read -r -a CFLAGS_PC <<<"$(pkg-config --cflags cairo pixman-1)"
read -r -a LIBS_PC <<<"$(pkg-config --libs cairo pixman-1)"
cc -O2 -Wall -Wextra -Werror -Wl,--export-dynamic \
    "${CFLAGS_PC[@]}" "$ROOT/scripts/pixman-cairo-access-regression.c" \
    "${LIBS_PC[@]}" "-Wl,-rpath-link,$STOCK_LIBDIR" -ldl -o "$WORK/test"
LD_LIBRARY_PATH="$PATCHED_LIBDIR:$STOCK_LIBDIR" "$WORK/test" --expect-hooks > "$WORK/patched"
LD_LIBRARY_PATH="$STOCK_LIBDIR" "$WORK/test" > "$WORK/stock"
diff -u <(grep '^pixels:' "$WORK/stock") <(grep '^pixels:' "$WORK/patched")
cat "$WORK/patched"
echo 'Patched and stock Cairo pixel output matches'
