#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" == Linux ]]; then
  cc -O2 -Wall -Wextra -Werror -pthread \
    "$ROOT/scripts/pixman-bridge-regression.c" -ldl -o /tmp/pixman-bridge-regression
  /tmp/pixman-bridge-regression
else
  instance="${PINECONE_CACHE_LIMA_INSTANCE:-pinecone-builder}"
  limactl shell "$instance" cc -O2 -Wall -Wextra -Werror -pthread \
    "$ROOT/scripts/pixman-bridge-regression.c" -ldl -o /tmp/pixman-bridge-regression
  limactl shell "$instance" /tmp/pixman-bridge-regression
fi
