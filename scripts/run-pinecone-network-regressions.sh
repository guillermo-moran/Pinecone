#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pinecone-network-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
sh -n "$ROOT/scripts/rootfs/pinecone-network"
sh -n "$ROOT/scripts/rootfs/pinecone-network-install"
sh -n "$ROOT/scripts/rootfs/arm64viz-root-init"
"${PYTHON:-python3}" "$ROOT/scripts/run-pinecone-network-regressions.py"
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror \
    "$ROOT/scripts/session-launcher-network-regression.c" -o "$WORK/launcher-network"
"$WORK/launcher-network"
