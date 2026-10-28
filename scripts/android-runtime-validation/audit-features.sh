#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/arm64viz-feature-audit.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
# This is a three-file standalone probe, not a package/app/guest build.
swiftc -module-cache-path "$work/module-cache" \
    "$root/Sources/ARM64VizCore/CPUState.swift" \
    "$root/Sources/ARM64VizCore/SystemRegisters.swift" \
    "$root/scripts/android-runtime-validation/feature-audit.swift" -o "$work/audit"
"$work/audit"
