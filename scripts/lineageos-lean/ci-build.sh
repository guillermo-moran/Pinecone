#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: ci-build.sh ANDROID_SOURCE_ROOT OUTPUT_DIRECTORY

Syncs a dedicated LineageOS checkout, builds the lean arm64viz product, and
stages its boot artifacts. This script is Linux-only and is suitable for a
persistent self-hosted CI runner.

Environment:
  LINEAGEOS_MANIFEST_URL  default: https://github.com/LineageOS/android.git
  LINEAGEOS_BRANCH        default: lineage-23.2
  LINEAGEOS_SYNC          1 to sync, 0 to use the existing checkout (default: 1)
  LINEAGEOS_SYNC_JOBS     repo sync jobs (default: 8)
  ARM64VIZ_BUILD_JOBS     Android build jobs (default: host CPU count)
  ARM64VIZ_MIN_FREE_GIB   required free disk before sync/build (default: 350)
  ARM64VIZ_MIN_OUTPUT_FREE_GIB  free disk for staged/upload files (default: 30)
EOF
  exit 64
}

[[ $# -eq 2 ]] || usage
[[ $(uname -s) == Linux ]] || {
  echo "LineageOS CI builds require a Linux host" >&2
  exit 69
}

source_root=$1
output_dir=$2
[[ "$source_root" == /* && "$output_dir" == /* ]] || {
  echo "ANDROID_SOURCE_ROOT and OUTPUT_DIRECTORY must be absolute paths" >&2
  exit 64
}
manifest_url=${LINEAGEOS_MANIFEST_URL:-https://github.com/LineageOS/android.git}
branch=${LINEAGEOS_BRANCH:-lineage-23.2}
sync_source=${LINEAGEOS_SYNC:-1}
sync_jobs=${LINEAGEOS_SYNC_JOBS:-8}
minimum_free_gib=${ARM64VIZ_MIN_FREE_GIB:-350}
minimum_output_free_gib=${ARM64VIZ_MIN_OUTPUT_FREE_GIB:-30}
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

[[ "$sync_source" == 0 || "$sync_source" == 1 ]] || {
  echo "LINEAGEOS_SYNC must be 0 or 1" >&2
  exit 64
}
for value_name in sync_jobs minimum_free_gib minimum_output_free_gib; do
  value=${!value_name}
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
    echo "$value_name must be a positive integer" >&2
    exit 64
  }
done

for tool in git git-lfs repo python3 qemu-img unzip zstd; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "missing required host tool: $tool" >&2
    exit 69
  }
done
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
  echo "missing SHA-256 tool (sha256sum or shasum)" >&2
  exit 69
fi

mkdir -p "$source_root"
source_root=$(cd "$source_root" && pwd)
output_parent=$(dirname "$output_dir")
mkdir -p "$output_parent"
output_parent=$(cd "$output_parent" && pwd)
output_dir="$output_parent/$(basename "$output_dir")"

check_free_space() {
  local storage_path=$1
  local required_gib=$2
  local required_kib=$((required_gib * 1024 * 1024))
  local available_kib
  available_kib=$(df -Pk "$storage_path" | awk 'NR == 2 { print $4 }')
  if (( available_kib < required_kib )); then
    echo "insufficient free disk at $storage_path: need ${required_gib} GiB, have $((available_kib / 1024 / 1024)) GiB" >&2
    exit 73
  fi
}
check_free_space "$source_root" "$minimum_free_gib"
check_free_space "$output_parent" "$minimum_output_free_gib"

if [[ ! -d "$source_root/.repo" ]]; then
  [[ "$sync_source" == 1 ]] || {
    echo "LINEAGEOS_SYNC=0 requires an initialized repo checkout: $source_root" >&2
    exit 66
  }
  (
    cd "$source_root"
    repo init \
      -u "$manifest_url" \
      -b "$branch" \
      --git-lfs \
      --no-clone-bundle
  )
fi

if [[ "$sync_source" == 1 ]]; then
  (
    cd "$source_root"
    repo sync \
      -c \
      --prune \
      --force-sync \
      --fail-fast \
      --retry-fetches=8 \
      -j"$sync_jobs"
  )
fi

[[ -f "$source_root/build/envsetup.sh" ]] || {
  echo "sync completed without build/envsetup.sh: $source_root" >&2
  exit 66
}

"$script_dir/build.sh" "$source_root" "$output_dir"
