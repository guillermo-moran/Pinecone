#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${PINECONE_HOST_RASTER_TEST_WORKDIR:-$(mktemp -d /tmp/pinecone-host-raster.XXXXXX)}"
mkdir -p "${WORK}"
read -r -a pixman_flags <<< "$(pkg-config --cflags --libs pixman-1)"
sources=("${ROOT}/scripts/host-raster-glyph-regression.c"
         "${ROOT}/Sources/ARM64VizNative/ARM64VizFramebuffer.c")
common=(-std=c11 -Wall -Wextra -I "${ROOT}/Sources/ARM64VizNative/include")

cc -O3 "${common[@]}" "${sources[@]}" "${pixman_flags[@]}" -o "${WORK}/glyph-regression"
"${WORK}/glyph-regression" | tee "${WORK}/glyph-regression.log"
cc -O2 -fsanitize=undefined -fno-sanitize-recover=all \
    "${common[@]}" "${sources[@]}" "${pixman_flags[@]}" -o "${WORK}/glyph-ubsan"
"${WORK}/glyph-ubsan" | tee "${WORK}/glyph-ubsan.log"

if [[ -n "${PINECONE_HOST_RASTER_BASELINE_SOURCE:-}" ]]; then
    library_flags=(-shared -fPIC)
    if [[ "$(uname -s)" == Darwin ]]; then library_flags=(-dynamiclib); fi
    cc -O3 "${common[@]}" "${library_flags[@]}" \
        "${PINECONE_HOST_RASTER_BASELINE_SOURCE}" -o "${WORK}/framebuffer-before.dylib"
    "${WORK}/glyph-regression" "${WORK}/framebuffer-before.dylib" | tee "${WORK}/glyph-benchmark.log"
fi
printf 'Evidence: %s\n' "${WORK}"
