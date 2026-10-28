#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${GRAPHICS_INTEGRATION_WORKDIR:-$(mktemp -d /tmp/arm64viz-graphics-integration.XXXXXX)}"
BUILD="${GRAPHICS_EXISTING_BUILD:-$ROOT/.build/arm64-apple-macosx/debug}"
mkdir -p "$WORK"
module_cache="$(mktemp -d "$WORK/module-cache.XXXXXX")"
trap 'rm -rf "$module_cache"' EXIT
# Reuse the parent's existing Swift build; do not start SwiftPM or an app build.
# This is preliminary evidence only until the parent rebuilds current sources.
test -f "$BUILD/Modules/ARM64VizCore.swiftmodule"
cc -O3 -I "$ROOT/Sources/ARM64VizNative/include" -c \
    "$ROOT/Sources/ARM64VizNative/ARM64VizFramebuffer.c" -o "$WORK/framebuffer.o"
native=()
for object in "$BUILD/ARM64VizNative.build/"*.o; do
    if [[ "$(basename "$object")" != ARM64VizFramebuffer.c.o ]]; then native+=("$object"); fi
done
frameworks="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
test_libraries="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib"
swiftc -O -module-cache-path "$module_cache" \
    -F "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" \
    -I "$test_libraries" -L "$test_libraries" -Xlinker -rpath -Xlinker "$test_libraries" \
    -I "$BUILD/Modules" -I "$BUILD/ARM64VizNative.build" \
    "$ROOT/Tests/ARM64VizCoreTests/GraphicsIdentityTests.swift" \
    "$ROOT/Tests/ARM64VizCoreTests/GPUCommandConcurrencyTests.swift" \
    "$ROOT/scripts/graphics-identity-integration-main.swift" \
    "$BUILD/ARM64VizCore.build/"*.swift.o "${native[@]}" "$WORK/framebuffer.o" \
    -o "$WORK/graphics-integration"
"$WORK/graphics-integration" 2>&1 | tee "$WORK/integration.log"
printf 'Preliminary existing-Swift-build evidence: %s\n' "$WORK"
