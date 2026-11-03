#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: build.sh ANDROID_SOURCE_ROOT [OUTPUT_DIRECTORY]

Builds arm64viz_virtio_arm64only_lean-user and stages bootable artifacts.
The source tree must already be a synced LineageOS 23.2 checkout.

Environment:
  ARM64VIZ_BUILD_JOBS   parallel build jobs (default: host CPU count)
  ARM64VIZ_M_TARGETS    make targets (default: "vm-utm-zip")
  QEMU_IMG              qemu-img executable used while staging
EOF
  exit 64
}

[[ $# -ge 1 && $# -le 2 ]] || usage
android_root=$(cd "$1" && pwd)
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
output_dir=${2:-"$repo_root/artifacts/lineageos-lean-local"}
if [[ "$output_dir" != /* ]]; then
  output_dir="$(pwd)/$output_dir"
fi

if [[ -n ${ARM64VIZ_BUILD_JOBS:-} ]]; then
  build_jobs=$ARM64VIZ_BUILD_JOBS
elif command -v nproc >/dev/null 2>&1; then
  build_jobs=$(nproc)
else
  build_jobs=$(getconf _NPROCESSORS_ONLN)
fi
[[ "$build_jobs" =~ ^[1-9][0-9]*$ ]] || {
  echo "ARM64VIZ_BUILD_JOBS must be a positive integer" >&2
  exit 64
}

"$script_dir/install-overlay.sh" "$android_root"

cd "$android_root"
# Android's envsetup intentionally defines shell functions and variables.
# shellcheck disable=SC1091
set +u
source build/envsetup.sh
set -u
export AB_OTA_UPDATER=false
lunch arm64viz_virtio_arm64only_lean-user

# This product shares TARGET_DEVICE (and therefore PRODUCT_OUT) with the
# upstream Go target. Remove installed files from a previous product selection
# so an obsolete HAL cannot leak into the staged image.
m installclean

read -r -a make_targets <<< "${ARM64VIZ_M_TARGETS:-vm-utm-zip}"
m -j"$build_jobs" "${make_targets[@]}"

product_out="$android_root/out/target/product/virtio_arm64only_go"
if [[ ! -d "$product_out" ]]; then
  product_out="$android_root/out/target/product/arm64viz_virtio_arm64only_lean"
fi
"$script_dir/verify-output.sh" "$product_out"
"$script_dir/stage-artifacts.sh" "$android_root" "$product_out" "$output_dir"

echo "Lean Android artifacts are ready in $output_dir"
