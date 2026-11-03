#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: package-ci-artifacts.sh STAGED_ARTIFACT_DIRECTORY OUTPUT_DIRECTORY

Creates a GNU sparse-tar + zstd bundle, split into upload-friendly pieces.
The duplicate UTM zip is intentionally omitted. Set ARM64VIZ_CI_CHUNK_MIB to
change the default 1800 MiB part size.
EOF
  exit 64
}

[[ $# -eq 2 ]] || usage
[[ $(uname -s) == Linux ]] || {
  echo "CI artifact packaging requires GNU tar on Linux" >&2
  exit 69
}

input_dir=$(cd "$1" && pwd)
output_dir=$2
chunk_mib=${ARM64VIZ_CI_CHUNK_MIB:-1800}
[[ "$chunk_mib" =~ ^[1-9][0-9]*$ ]] || {
  echo "ARM64VIZ_CI_CHUNK_MIB must be a positive integer" >&2
  exit 64
}

for tool in tar zstd split sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "missing required packaging tool: $tool" >&2
    exit 69
  }
done
tar_version=$(tar --version)
grep -q 'GNU tar' <<< "$tar_version" || {
  echo "package-ci-artifacts.sh requires GNU tar sparse-file support" >&2
  exit 69
}

for required in boot.img vendor_boot.img vda.raw vdb.raw SHA256SUMS; do
  [[ -f "$input_dir/$required" ]] || {
    echo "missing staged artifact: $required" >&2
    exit 66
  }
done
[[ ! -e "$output_dir" ]] || {
  echo "refusing to overwrite CI package directory: $output_dir" >&2
  exit 73
}
mkdir -p "$output_dir"

files=(
  boot.img
  vendor_boot.img
  vda.raw
  vdb.raw
  SHA256SUMS
  pinned-manifest.xml
  build-metadata.txt
  overlay-SHA256SUMS
  arm64viz-lean-overlay.tar.gz
)
[[ -f "$input_dir/init_boot.img" ]] && files+=(init_boot.img)

for optional_index in "${!files[@]}"; do
  [[ -f "$input_dir/${files[$optional_index]}" ]] || unset 'files[optional_index]'
done
files=("${files[@]}")

temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/arm64viz-lineageos-ci.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM
archive="$temporary_dir/arm64viz-lineageos-lean.tar.zst"

tar --sparse --format=pax -C "$input_dir" -cf - "${files[@]}" |
  zstd -T0 -10 -o "$archive"

split \
  --bytes="${chunk_mib}M" \
  --numeric-suffixes=0 \
  --suffix-length=4 \
  "$archive" \
  "$output_dir/arm64viz-lineageos-lean.tar.zst.part-"

(
  cd "$output_dir"
  sha256sum arm64viz-lineageos-lean.tar.zst.part-* > PART-SHA256SUMS
)

cat > "$output_dir/README.txt" <<'EOF'
Reassemble and extract on Linux:

  sha256sum -c PART-SHA256SUMS
  cat arm64viz-lineageos-lean.tar.zst.part-* > arm64viz-lineageos-lean.tar.zst
  zstd -dc arm64viz-lineageos-lean.tar.zst | tar -xf -

The archive is a GNU sparse tar. Extract to a filesystem with enough logical
space for vda.raw and vdb.raw; sparse extents avoid allocating their zero runs.
The UTM-VM zip is excluded because it duplicates the two staged raw disks.
EOF

{
  printf 'uncompressed_logical_bytes=%s\n' "$(du -cb "${files[@]/#/$input_dir/}" | tail -1 | cut -f1)"
  printf 'compressed_bytes=%s\n' "$(stat -c %s "$archive")"
  printf 'chunk_mib=%s\n' "$chunk_mib"
  printf 'chunk_count=%s\n' "$(find "$output_dir" -maxdepth 1 -type f -name 'arm64viz-lineageos-lean.tar.zst.part-*' | wc -l)"
} > "$output_dir/bundle-metadata.txt"

echo "CI upload bundle is ready in $output_dir"
