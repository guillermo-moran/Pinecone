#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:-$ROOT/artifacts/linux-shell/out/pinecone-packages}"
INSTANCE="${PINECONE_CACHE_LIMA_INSTANCE:-pinecone-builder}"
if [[ "$(uname -s)" != Linux ]]; then
  REMOTE="$(limactl shell --shell /bin/sh "$INSTANCE" mktemp -d /tmp/pinecone-packages-build.XXXXXX)"
  trap 'limactl shell --shell /bin/sh "$INSTANCE" rm -rf "$REMOTE" >/dev/null 2>&1 || true' EXIT
  limactl shell --shell /bin/sh "$INSTANCE" bash "$ROOT/scripts/build-pinecone-packages.sh" "$REMOTE/pinecone-packages"
  mkdir -p "$(dirname "$OUTPUT")"
  limactl copy "$INSTANCE:$REMOTE/pinecone-packages" "$OUTPUT"
else
  [[ "$(uname -m)" == aarch64 ]]
  # Build dependencies are deliberately not installed/upgraded as a side effect.
  pkg-config --exists gtk+-3.0 json-glib-1.0
  cc -std=c11 -O2 -Wall -Wextra -Werror -Wformat=2 -fstack-protector-strong \
    "$ROOT/scripts/rootfs/pinecone-packages.c" -o "$OUTPUT" \
    $(pkg-config --cflags --libs gtk+-3.0 json-glib-1.0) -Wl,-z,relro,-z,now
  "$OUTPUT" --self-test
fi
