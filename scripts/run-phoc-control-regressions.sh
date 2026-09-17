#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
for name in pinecone-trace.c pinecone-trace.h; do
  awk -v name="$name" '
    /^\+\+\+ b\/src\// { active=($0 == "+++ b/src/" name); next }
    active && /^\+/ { print substr($0, 2) }
  ' "$ROOT/scripts/patches/phoc-pinecone-interactions.patch" > "$WORK/$name"
done
cc -Wall -Wextra -Werror -I"$WORK" $(pkg-config --cflags glib-2.0) \
  "$ROOT/scripts/phoc-control-regression.c" $(pkg-config --libs glib-2.0) -o "$WORK/test"
"$WORK/test"
echo 'Phoc control regressions passed (tracing disabled and exhausted, dropped frame, invalid app).'
