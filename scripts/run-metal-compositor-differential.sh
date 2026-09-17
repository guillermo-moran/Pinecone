#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${TMPDIR:-/tmp}/pinecone-metal-differential"
mkdir -p "${WORK}"
export CLANG_MODULE_CACHE_PATH="${WORK}/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH="${WORK}/swift-module-cache"

cc -O2 -std=c11 \
  "${ROOT}/scripts/pixman-metal-golden.c" \
  $(pkg-config --cflags --libs pixman-1) \
  -o "${WORK}/pixman-metal-golden"
"${WORK}/pixman-metal-golden" > "${WORK}/golden.txt"

sed '/^import ARM64VizCore$/d' \
  "${ROOT}/Apps/iOS/MobileOSHost/Sources/PineconeMetalGraphicsAccelerator.swift" \
  > "${WORK}/main.swift"
printf '\n' >> "${WORK}/main.swift"
cat "${ROOT}/scripts/metal-compositor-differential-main.swift" \
  >> "${WORK}/main.swift"

for mode in direct simulator-copy; do
flags=(-D PINECONE_TEST_DIRECT)
if [[ "$mode" == simulator-copy ]]; then
  flags=(-D PINECONE_TEST_SIMULATOR_COPY)
fi
xcrun swiftc -O "${flags[@]}" \
  "${ROOT}/Sources/ARM64VizCore/ParavirtualGraphics.swift" \
  "${WORK}/main.swift" \
  -framework Metal \
  -o "${WORK}/metal-compositor-differential"

PINECONE_METAL_MIN_PIXELS=0 \
  "${WORK}/metal-compositor-differential" "${WORK}/golden.txt"
done
