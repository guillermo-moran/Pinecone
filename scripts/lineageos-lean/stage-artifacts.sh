#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 ANDROID_SOURCE_ROOT PRODUCT_OUT OUTPUT_DIRECTORY" >&2
  exit 64
}

[[ $# -eq 3 ]] || usage
android_root=$(cd "$1" && pwd)
product_out=$(cd "$2" && pwd)
output_dir=$3
qemu_img=${QEMU_IMG:-qemu-img}
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

command -v "$qemu_img" >/dev/null
command -v unzip >/dev/null
if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$@"; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$@"; }
else
  echo "missing SHA-256 tool (sha256sum or shasum)" >&2
  exit 69
fi

[[ ! -e "$output_dir" ]] || {
  echo "refusing to overwrite existing output directory: $output_dir" >&2
  exit 73
}
mkdir -p "$output_dir"

for image in boot.img vendor_boot.img init_boot.img; do
  [[ -f "$product_out/$image" ]] && install -m 0644 "$product_out/$image" "$output_dir/$image"
done

utm_zip=$(find "$product_out" -type f -name 'UTM-VM-*.zip' -print | sort | tail -1)
[[ -n "$utm_zip" ]] || {
  echo "vm-utm-zip did not produce a UTM archive under $product_out" >&2
  exit 66
}
install -m 0644 "$utm_zip" "$output_dir/$(basename "$utm_zip")"

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/arm64viz-lean-stage.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
unzip -q "$utm_zip" -d "$work_dir"

vda=$(find "$work_dir" -type f -name vda.qcow2 -print -quit)
vdb=$(find "$work_dir" -type f -name vdb.qcow2 -print -quit)
[[ -n "$vda" && -n "$vdb" ]] || {
  echo "UTM archive does not contain vda.qcow2 and vdb.qcow2" >&2
  exit 66
}
"$qemu_img" convert -p -f qcow2 -O raw -S 4096 "$vda" "$output_dir/vda.raw"
"$qemu_img" convert -p -f qcow2 -O raw -S 4096 "$vdb" "$output_dir/vdb.raw"

(
  cd "$android_root"
  if command -v repo >/dev/null 2>&1; then
    repo manifest -r
  else
    echo '<!-- repo tool unavailable; manifest snapshot not captured -->'
  fi
) > "$output_dir/pinned-manifest.xml"

{
  printf 'product=arm64viz_virtio_arm64only_lean\n'
  printf 'variant=user\n'
  printf 'source_root=%s\n' "$android_root"
  printf 'built_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$output_dir/build-metadata.txt"

# Preserve the exact overlay independently of the moving Lineage maintenance
# branch. Its checksums also make local edits visible in build provenance.
(
  cd "$script_dir"
  find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do
    sha256 "$file"
  done
) > "$output_dir/overlay-SHA256SUMS"
tar -czf "$output_dir/arm64viz-lean-overlay.tar.gz" -C "$script_dir" .

(
  cd "$output_dir"
  sha256 ./* > SHA256SUMS
)
