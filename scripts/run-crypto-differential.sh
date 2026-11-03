#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/pinecone-crypto.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
clang -O2 -std=c11 -Wall -Wextra -Werror \
    -fsanitize=undefined -fno-sanitize-recover=all \
    -I "$root/Sources/ARM64VizNative" \
    "$root/scripts/crypto-differential.c" -o "$work/check"
"$work/check"
