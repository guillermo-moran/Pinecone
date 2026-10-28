#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${GRAPHICS_IDENTITY_WORKDIR:-$(mktemp -d /tmp/arm64viz-graphics-identity-test.XXXXXX)}"
mkdir -p "$WORK"
read -r -a pixman_flags <<< "$(pkg-config --cflags --libs pixman-1)"
common=(-std=c11 -Wall -Wextra -Werror -I "$ROOT/Sources/ARM64VizNative/include")
sources=("$ROOT/scripts/graphics-identity-regression.c" "$ROOT/Sources/ARM64VizNative/ARM64VizFramebuffer.c")
baseline=()
if [[ $# -gt 0 ]]; then
    library_flags=(-shared -fPIC)
    if [[ "$(uname -s)" == Darwin ]]; then library_flags=(-dynamiclib); fi
    cc -O3 "${common[@]}" "${library_flags[@]}" "$1" -o "$WORK/before.dylib"
    baseline=("$WORK/before.dylib")
fi
cc -O3 "${common[@]}" "${sources[@]}" "${pixman_flags[@]}" -o "$WORK/identity"
"$WORK/identity" "${baseline[@]}" | tee "$WORK/identity.log"
cc -O1 -g -fsanitize="${GRAPHICS_IDENTITY_SANITIZERS:-undefined}" -fno-sanitize-recover=all \
    "${common[@]}" "${sources[@]}" "${pixman_flags[@]}" -o "$WORK/identity-sanitized"
"$WORK/identity-sanitized" | tee "$WORK/identity-sanitized.log"
printf 'Evidence: %s\n' "$WORK"
