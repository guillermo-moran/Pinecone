#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${1:?Pass the patched glib-2.88.3 source directory}"
OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/pinecone-mime-test.XXXXXX")"
trap 'rm -rf "$OUTPUT"' EXIT
flags=(-O2 -Wall -Werror -DHAVE_MMAP)
if [[ "$(uname -s)" == Darwin ]]; then
  flags+=(-isysroot "$(xcrun --sdk macosx --show-sdk-path)")
fi
if [[ "${PINECONE_MIME_SANITIZERS:-0}" == 1 ]]; then
  flags+=(-fsanitize=address,undefined -fno-omit-frame-pointer)
fi
sources=()
for source in "$SOURCE"/gio/xdgmime/*.c; do
  [[ "${source##*/}" == xdgmimecache.c ]] || sources+=("$source")
done
"${CC:-cc}" "${flags[@]}" -I "$SOURCE/gio/xdgmime" \
  "$ROOT/scripts/glib-mime-regression.c" "${sources[@]}" -o "$OUTPUT/regression"
"$OUTPUT/regression"
