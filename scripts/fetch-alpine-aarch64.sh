#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-"$ROOT_DIR/artifacts/alpine-aarch64"}"
BASE_URL="${ALPINE_NETBOOT_BASE:-https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/netboot}"

mkdir -p "$OUT_DIR"

download() {
    local name="$1"
    local target="$OUT_DIR/$name"
    if [ -s "$target" ]; then
        echo "[alpine] keeping existing $target"
        return
    fi
    echo "[alpine] downloading $name"
    curl -L --fail --output "$target" "$BASE_URL/$name"
}

discover_netboot_artifact() {
    local regex="$1"
    curl -fsSL "$BASE_URL/" |
        awk -F'"' -v regex="$regex" '$2 ~ regex { print $2; exit }'
}

copy_stable_name() {
    local source_name="$1"
    local stable_name="$2"
    cp "$OUT_DIR/$source_name" "$OUT_DIR/$stable_name"
    echo "[alpine] wrote stable alias $OUT_DIR/$stable_name"
}

download "vmlinuz-virt"
download "initramfs-virt"

system_map_name="$(discover_netboot_artifact '^System[.]map-[^-]+[.][^-]+[.][^-]+-.*-virt$')"
if [ -n "$system_map_name" ]; then
    download "$system_map_name"
    copy_stable_name "$system_map_name" "System.map-virt"
else
    echo "[alpine] warning: could not discover System.map for virt kernel" >&2
fi

config_name="$(discover_netboot_artifact '^config-[^-]+[.][^-]+[.][^-]+-.*-virt$')"
if [ -n "$config_name" ]; then
    download "$config_name"
    copy_stable_name "$config_name" "config-virt"
else
    echo "[alpine] warning: could not discover config for virt kernel" >&2
fi

payload_offset="$(grep -aob $'\x1f\x8b\x08' "$OUT_DIR/vmlinuz-virt" | head -n 1 | cut -d: -f1)"
if [ -z "$payload_offset" ]; then
    echo "[alpine] could not find gzip payload inside vmlinuz-virt" >&2
    exit 1
fi

echo "[alpine] extracting gzip payload at byte offset $payload_offset"
dd if="$OUT_DIR/vmlinuz-virt" of="$OUT_DIR/Image.gz" bs=1 skip="$payload_offset"

echo "[alpine] decompressing raw ARM64 Linux Image"
set +e
gzip -dc "$OUT_DIR/Image.gz" > "$OUT_DIR/Image"
gzip_status=$?
set -e
if [ "$gzip_status" -ne 0 ] && [ "$gzip_status" -ne 2 ]; then
    echo "[alpine] gzip failed with status $gzip_status" >&2
    exit "$gzip_status"
fi

if [ ! -s "$OUT_DIR/Image" ]; then
    echo "[alpine] extracted Image is empty" >&2
    exit 1
fi

echo "[alpine] artifacts:"
ls -lh "$OUT_DIR/Image" "$OUT_DIR/initramfs-virt" "$OUT_DIR/vmlinuz-virt"
if [ -s "$OUT_DIR/System.map-virt" ]; then
    ls -lh "$OUT_DIR/System.map-virt"
fi

if command -v file >/dev/null 2>&1; then
    file "$OUT_DIR/Image"
fi

if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$OUT_DIR/Image" "$OUT_DIR/initramfs-virt" "$OUT_DIR/vmlinuz-virt"
    if [ -s "$OUT_DIR/System.map-virt" ]; then
        shasum -a 256 "$OUT_DIR/System.map-virt"
    fi
fi

cat <<EOF

[alpine] handoff:
swift run arm64viz prepare-linux "$OUT_DIR/Image" \\
  --initrd "$OUT_DIR/initramfs-virt" \\
  --memory-mib 128 \\
  --bootargs "console=ttyAMA0 earlycon=pl011,mmio32,0x9000000 rdinit=/bin/sh loglevel=8"

[alpine] trace:
swift run arm64viz run-linux-trace "$OUT_DIR/Image" \\
  --initrd "$OUT_DIR/initramfs-virt" \\
  --memory-mib 128 \\
  --max-steps 16 \\
  --trace-depth 16 \\
  --symbols "$OUT_DIR/System.map-virt" \\
  --bootargs "console=ttyAMA0 earlycon=pl011,mmio32,0x9000000 rdinit=/bin/sh loglevel=8"
EOF
