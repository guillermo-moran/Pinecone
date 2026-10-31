#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${TMPDIR:-/tmp}/pinecone-metal-differential"
SIMULATOR=""
if [[ $# -gt 0 ]]; then
  if [[ $# -ne 2 || "$1" != "--simulator" ]]; then
    echo "usage: $0 [--simulator BOOTED-UDID]" >&2
    exit 2
  fi
  SIMULATOR="$2"
  WORK="${WORK}-simulator"
fi
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

if [[ -n "$SIMULATOR" ]]; then
  # Use the actual iOS Simulator Metal implementation, not just its copy path
  # compiled for macOS. These implementations have different capabilities.
  APP="${WORK}/PineconeMetalRegression.app"
  mkdir -p "$APP"
  cp "${WORK}/golden.txt" "$APP/golden.txt"
  /usr/bin/plutil -create xml1 "$APP/Info.plist"
  /usr/bin/plutil -replace CFBundleIdentifier -string me.gmoran.pinecone.metal-regression "$APP/Info.plist"
  /usr/bin/plutil -replace CFBundleExecutable -string PineconeMetalRegression "$APP/Info.plist"
  /usr/bin/plutil -replace CFBundleName -string PineconeMetalRegression "$APP/Info.plist"
  /usr/bin/plutil -replace CFBundlePackageType -string APPL "$APP/Info.plist"
  /usr/bin/plutil -replace CFBundleVersion -string 1 "$APP/Info.plist"
  /usr/bin/plutil -replace CFBundleSupportedPlatforms -json '["iPhoneSimulator"]' "$APP/Info.plist"
  xcrun --sdk iphonesimulator swiftc -O -D PINECONE_TEST_SIMULATOR_COPY \
    -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -target "$(uname -m)-apple-ios18.0-simulator" \
    "${ROOT}/Sources/ARM64VizCore/ParavirtualGraphics.swift" \
    "${WORK}/main.swift" -framework Metal -o "$APP/PineconeMetalRegression"
  codesign --force --sign - "$APP"
  xcrun simctl install "$SIMULATOR" "$APP"
  INSTALLED="$(xcrun simctl get_app_container "$SIMULATOR" me.gmoran.pinecone.metal-regression app)"
  SIMCTL_CHILD_MTL_DEBUG_LAYER=1 SIMCTL_CHILD_PINECONE_METAL_MIN_PIXELS=0 \
    xcrun simctl launch --console --terminate-running-process "$SIMULATOR" \
    me.gmoran.pinecone.metal-regression "$INSTALLED/golden.txt" 2>&1 | tee "$WORK/result.log"
  grep -q 'Metal compositor matches Pixman' "$WORK/result.log"
  if grep -q 'failed assertion' "$WORK/result.log"; then exit 1; fi
  exit 0
fi

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

MTL_DEBUG_LAYER=1 PINECONE_METAL_MIN_PIXELS=0 \
  "${WORK}/metal-compositor-differential" "${WORK}/golden.txt"
done
