#!/bin/sh
set -eu

output_path="${1:-artifacts/lineageos-virtio-arm64only-v2026.10.18/vdb-arm64viz.raw}"
size_gib="${LINEAGE_USERDATA_GIB:-8}"

case "$size_gib" in
  '' | *[!0-9]*)
    echo "LINEAGE_USERDATA_GIB must be a positive integer" >&2
    exit 2
    ;;
esac
if [ "$size_gib" -le 0 ]; then
  echo "LINEAGE_USERDATA_GIB must be a positive integer" >&2
  exit 2
fi
if [ -e "$output_path" ]; then
  echo "refusing to overwrite existing userdata image: $output_path" >&2
  exit 2
fi

find_e2fsprogs_tool() {
  tool_name="$1"
  if command -v "$tool_name" >/dev/null 2>&1; then
    command -v "$tool_name"
    return
  fi
  for candidate in \
    "/opt/homebrew/opt/e2fsprogs/sbin/$tool_name" \
    "/usr/local/opt/e2fsprogs/sbin/$tool_name"
  do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  echo "missing $tool_name; install e2fsprogs first" >&2
  exit 2
}

mke2fs="$(find_e2fsprogs_tool mke2fs)"
e2fsck="$(find_e2fsprogs_tool e2fsck)"

mkdir -p "$(dirname "$output_path")"
truncate -s "${size_gib}G" "$output_path"
if ! "$mke2fs" -F -t ext4 -b 4096 -m 0 -L userdata \
  -O quota,project "$output_path"; then
  echo "format failed; incomplete image retained at $output_path" >&2
  exit 1
fi
if ! "$e2fsck" -fn "$output_path"; then
  echo "validation failed; image retained at $output_path" >&2
  exit 1
fi

echo "created clean ${size_gib} GiB Android userdata image: $output_path"
