#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE="${1:?Usage: run-attribution-regressions.sh phoc-0.57.0.tar.xz [dedicated-output-dir]}"
WORK="${2:-$(mktemp -d /tmp/pinecone-attribution.XXXXXX)}"
mkdir -p "$WORK/source" "$WORK/swift/Sources/ARM64VizCore" "$WORK/swift/Tests/ARM64VizCoreTests"
cmp "$ROOT/scripts/patches/phoc-pinecone-interactions.patch" "$ROOT/scripts/alpine/phoc/phoc-pinecone-interactions.patch"
tar -xf "$ARCHIVE" -C "$WORK/source" phoc-0.57.0/src phoc-0.57.0/meson.build
SOURCE="$WORK/source/phoc-0.57.0"
for patch_name in phoc-pinecone-layout phoc-pinecone-interactions; do
  patch --batch --fuzz=0 -p1 -d "$SOURCE" -i "$ROOT/scripts/patches/$patch_name.patch" > "$WORK/$patch_name.log"
  if grep -Ei 'offset|fuzz|FAILED|reject' "$WORK/$patch_name.log"; then exit 1; fi
done
EXTRA=()
if [[ "${ATTRIBUTION_SANITIZE:-0}" == 1 ]]; then
  EXTRA=(-fsanitize=address,undefined -fno-omit-frame-pointer)
elif [[ "${ATTRIBUTION_SANITIZE:-0}" == undefined ]]; then
  EXTRA=(-fsanitize=undefined -fno-sanitize-recover=all)
fi
SDK=()
if [[ "$(uname -s)" == Darwin ]]; then SDK=(-isysroot "$(xcrun --sdk macosx --show-sdk-path)"); fi
"${CC:-cc}" -std=gnu11 -g -Wall -Wextra -Werror \
  ${EXTRA[@]+"${EXTRA[@]}"} ${SDK[@]+"${SDK[@]}"} \
  -I"$SOURCE/src" $(pkg-config --cflags glib-2.0) \
  "$ROOT/scripts/phoc-attribution-regression.c" $(pkg-config --libs glib-2.0) \
  -o "$WORK/phoc-attribution-regression"
"$WORK/phoc-attribution-regression" disabled | tee "$WORK/c-disabled.log"
"$WORK/phoc-attribution-regression" enabled | tee "$WORK/c-enabled.log"
for name in TouchPipeline GuestGraphicsTrace VMPerformanceTimeline ApplicationExecutionPolicy; do
  cp "$ROOT/Sources/ARM64VizCore/$name.swift" "$WORK/swift/Sources/ARM64VizCore/"
done
cp "$ROOT/scripts/attribution-regression-package.swift" "$WORK/swift/Package.swift"
cp "$ROOT/Tests/ARM64VizCoreTests/InputFrameAttributionTests.swift" "$WORK/swift/Tests/ARM64VizCoreTests/"
CLANG_MODULE_CACHE_PATH="$WORK/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$WORK/module-cache" \
  swift test --disable-sandbox --package-path "$WORK/swift" --scratch-path "$WORK/swift-build" \
  --cache-path "$WORK/swift-cache" --config-path "$WORK/swift-config" --security-path "$WORK/swift-security" \
  2>&1 | tee "$WORK/swift-tests.log"
printf 'Attribution regression evidence: %s\n' "$WORK"
