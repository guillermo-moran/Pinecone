#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 ANDROID_SOURCE_ROOT" >&2
  exit 64
}

[[ $# -eq 1 ]] || usage
android_root=$(cd "$1" && pwd)
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
product_source="$script_dir/product"
product_destination="$android_root/device/arm64viz/virtio_arm64only_lean"
graphics_source="$script_dir/../android-graphics"
graphics_destination="$android_root/device/arm64viz/pinecone_graphics"
virt_common="$android_root/device/virt/virt-common"
mainline_common="$android_root/device/mainline/common"
virt_product="$android_root/device/virt/virtio_arm64only/aosp_virtio_arm64only_go.mk"
optional_patch="$script_dir/patches/0001-make-optional-virt-hardware-overridable.patch"
wifi_patch="$script_dir/patches/0002-gate-mainline-wifi-payload.patch"

[[ -f "$android_root/build/envsetup.sh" ]] || {
  echo "not an Android source root: $android_root" >&2
  exit 66
}
[[ -f "$virt_product" ]] || {
  echo "missing LineageOS virtio_arm64only product (expected lineage-23.2): $virt_product" >&2
  exit 66
}
[[ -f "$virt_common/virt-common.mk" ]] || {
  echo "missing VirtIO common device tree: $virt_common" >&2
  exit 66
}
[[ -f "$mainline_common/mainline_common.mk" ]] || {
  echo "missing mainline common device tree: $mainline_common" >&2
  exit 66
}

mkdir -p "$product_destination"
install -m 0644 "$product_source/AndroidProducts.mk" "$product_destination/AndroidProducts.mk"
install -m 0644 "$product_source/arm64viz_virtio_arm64only_lean.mk" \
  "$product_destination/arm64viz_virtio_arm64only_lean.mk"

# Buildable transport library only; no composer service is selected or replaced.
mkdir -p "$graphics_destination"
for graphics_file in Android.bp pinecone_layer_encoder.h pinecone_drm_transport.h pinecone_drm_transport.c; do
  install -m 0644 "$graphics_source/$graphics_file" "$graphics_destination/$graphics_file"
done

if grep -q '^TARGET_ENABLE_VIRT_WIFI ?= true$' "$virt_common/virt-common.mk"; then
  echo "VirtIO optional-hardware patch is already applied"
else
  git -C "$virt_common" apply --check "$optional_patch"
  git -C "$virt_common" apply "$optional_patch"
  echo "Applied optional-hardware patch to device/virt/virt-common"
fi

if grep -q '^ifeq ($(TARGET_ENABLE_VIRT_WIFI),true)$' "$mainline_common/mainline_common.mk"; then
  echo "Mainline Wi-Fi payload patch is already applied"
else
  git -C "$mainline_common" apply --check "$wifi_patch"
  git -C "$mainline_common" apply "$wifi_patch"
  echo "Applied Wi-Fi payload patch to device/mainline/common"
fi

echo "Installed arm64viz lean product at device/arm64viz/virtio_arm64only_lean"
