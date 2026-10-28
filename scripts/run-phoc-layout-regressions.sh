#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE="${1:-${PHOC_SOURCE_ARCHIVE:-}}"
if [[ $# -gt 1 || ! -f "$ARCHIVE" ]]; then
  echo "Usage: $0 /path/to/phoc-0.57.0.tar.xz (or set PHOC_SOURCE_ARCHIVE)" >&2
  exit 1
fi
cmp "$ROOT/scripts/patches/phoc-pinecone-layout.patch" \
    "$ROOT/scripts/alpine/phoc/phoc-pinecone-layout.patch"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
tar -xf "$ARCHIVE" -C "$WORK" phoc-0.57.0/src phoc-0.57.0/meson.build
SOURCE="$WORK/phoc-0.57.0"
grep -Eq "version: *'0\.57\.0'" "$SOURCE/meson.build"
# Reject offsets/fuzz as well as failed hunks against the exact release.
patch --batch --fuzz=0 -p1 -d "$SOURCE" \
  < "$ROOT/scripts/patches/phoc-pinecone-layout.patch" > "$WORK/patch.log"
if grep -Ei 'offset|fuzz|FAILED|reject' "$WORK/patch.log"; then
  exit 1
fi
touch "$SOURCE/src/phoc-config.h"

# Compile the production callback bodies too, with only compositor dependencies
# stubbed by the harness. No transaction or serial logic is copied into the test.
awk '
  /^(handle_surface_commit|handle_unmap|handle_destroy|phoc_layer_surface_send_configure) \(/ {
    active = 1; count++; print previous
  }
  active { print }
  active && /^}/ { active = 0 }
  { previous = $0 }
  END { if (count != 4) exit 1 }
' "$SOURCE/src/layer-surface.c" > "$WORK/layer-callbacks.inc"
awk '
  /^struct _PhocLayerSurface \{/ { active = 1; count++ }
  active { print }
  active && /^};/ { active = 0 }
  END { if (count != 1) exit 1 }
' "$SOURCE/src/layer-surface.h" > "$WORK/layer-struct.inc"

# PHOC_TEST_SANITIZE=1 adds ASan/UBSan; "undefined" runs UBSan alone.
EXTRA=()
case "${PHOC_TEST_SANITIZE:-0}" in
  0) ;;
  1) EXTRA=(-fsanitize=address,undefined -fno-omit-frame-pointer) ;;
  undefined) EXTRA=(-fsanitize=undefined -fno-omit-frame-pointer) ;;
  *) echo 'PHOC_TEST_SANITIZE must be 0, 1, or undefined' >&2; exit 1 ;;
esac
"${CC:-cc}" -std=gnu11 -g -Wall -Wextra -Werror -Wno-unused-parameter \
  ${EXTRA[@]+"${EXTRA[@]}"} -I"$SOURCE/src" -I"$WORK" \
  $(pkg-config --cflags gobject-2.0) \
  "$ROOT/scripts/phoc-layout-regression.c" \
  $(pkg-config --libs gobject-2.0) -o "$WORK/phoc-layout-regression"
G_DEBUG=fatal-warnings "$WORK/phoc-layout-regression"
echo 'Phoc layout regressions passed against patched upstream 0.57.0.'
