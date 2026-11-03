#!/bin/sh
set -eu

release_tag="v2026.10.18"
release_name="lineage-23.2-20261019-jqssun"
artifact_dir="artifacts/lineageos-virtio-arm64only-${release_tag}"
boot_asset="boot_arm64only.img"
utm_asset="UTM-VM-${release_name}-virtio_arm64only.zip"
release_url="https://github.com/jqssun/android-lineage-qemu/releases/download/${release_tag}"
boot_sha256="d3efda5df6e2bdd152de6814bffc0b9050925ddd7f3c114cd3dd68c02a758cf5"
utm_sha256="171c0d215899d68f070fd45aea05ddb25737cf4ff16a25468e7cafbc65f4d8c9"
lineage_qemu_img="${LINEAGE_QEMU_IMG:-qemu-img}"

command -v curl >/dev/null
command -v unzip >/dev/null
command -v shasum >/dev/null
command -v "$lineage_qemu_img" >/dev/null

mkdir -p "$artifact_dir"

if [ ! -f "$artifact_dir/boot.img" ]; then
  curl -fL "$release_url/$boot_asset" -o "$artifact_dir/boot.img"
fi
if [ ! -f "$artifact_dir/$utm_asset" ]; then
  curl -fL "$release_url/$utm_asset" -o "$artifact_dir/$utm_asset"
fi

(
  cd "$artifact_dir"
  printf '%s  %s\n' "$boot_sha256" "boot.img" | shasum -a 256 -c -
  printf '%s  %s\n' "$utm_sha256" "$utm_asset" | shasum -a 256 -c -
  unzip -q -o "$utm_asset"
)

utm_data="$artifact_dir/LineageOS_on_arm64.utm/Data"
"$lineage_qemu_img" convert -p -f qcow2 -O raw -S 4096 \
  "$utm_data/vda.qcow2" "$artifact_dir/vda.raw"
"$lineage_qemu_img" convert -p -f qcow2 -O raw -S 4096 \
  "$utm_data/vdb.qcow2" "$artifact_dir/vdb.raw"

# GPT partition 11 (vendor_boot): first LBA 9650176, 204800 sectors.
dd if="$artifact_dir/vda.raw" of="$artifact_dir/vendor_boot.img" \
  bs=512 skip=9650176 count=204800

printf 'LineageOS artifacts are ready in %s\n' "$artifact_dir"
