#!/bin/sh
set -eu

# The pinned virtio_arm64only release loads virt_wifi.ko unconditionally. That
# optional module faults under Pinecone before Android reaches SurfaceFlinger.
# Replace only vendor_dlkm's modules.load and leave the downloaded vda.raw
# untouched so the workaround is easy to audit and remove.

artifact_dir="${1:-artifacts/lineageos-virtio-arm64only-v2026.10.18}"
source_disk="${2:-$artifact_dir/vda.raw}"
output_disk="${3:-$artifact_dir/vda-arm64viz.raw}"
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
modules_load="$script_dir/lineageos-modules.load"
lineage_lpunpack="${LINEAGE_LPUNPACK:-lpunpack}"
lineage_debugfs="${LINEAGE_DEBUGFS:-debugfs}"
lineage_e2fsck="${LINEAGE_E2FSCK:-e2fsck}"

if ! command -v "$lineage_debugfs" >/dev/null 2>&1 && [ -x /opt/homebrew/opt/e2fsprogs/sbin/debugfs ]; then
  lineage_debugfs=/opt/homebrew/opt/e2fsprogs/sbin/debugfs
fi
if ! command -v "$lineage_e2fsck" >/dev/null 2>&1 && [ -x /opt/homebrew/opt/e2fsprogs/sbin/e2fsck ]; then
  lineage_e2fsck=/opt/homebrew/opt/e2fsprogs/sbin/e2fsck
fi

command -v "$lineage_lpunpack" >/dev/null
command -v "$lineage_debugfs" >/dev/null
command -v "$lineage_e2fsck" >/dev/null
test -f "$source_disk"
test -f "$modules_load"

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/arm64viz-lineage.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
mkdir -p "$work_dir/partitions"

# GPT partition 5 (super): first LBA 526336, 8388608 sectors.
dd if="$source_disk" of="$work_dir/super.img" bs=512 skip=526336 count=8388608
"$lineage_lpunpack" "$work_dir/super.img" "$work_dir/partitions"

vendor_dlkm="$work_dir/partitions/vendor_dlkm.img"
test -f "$vendor_dlkm"
"$lineage_debugfs" -w -R "rm /lib/modules/modules.load" "$vendor_dlkm"
"$lineage_debugfs" -w -R "write $modules_load /lib/modules/modules.load" "$vendor_dlkm"
printf 'u:object_r:vendor_file:s0\0' > "$work_dir/selinux-label"
"$lineage_debugfs" -w -R \
  "ea_set -f $work_dir/selinux-label -r /lib/modules/modules.load security.selinux" \
  "$vendor_dlkm"
"$lineage_e2fsck" -fy "$vendor_dlkm"

cp -c "$source_disk" "$output_disk" 2>/dev/null || cp "$source_disk" "$output_disk"
vendor_blocks=$((($(wc -c < "$vendor_dlkm") + 4095) / 4096))

# vendor_dlkm's sole logical extent begins 2 MiB into super. With super at
# LBA 526336, that is global 4096-byte block 66304.
dd if="$vendor_dlkm" of="$output_disk" bs=4096 seek=66304 count="$vendor_blocks" conv=notrunc

printf 'Patched LineageOS disk is ready at %s\n' "$output_disk"
