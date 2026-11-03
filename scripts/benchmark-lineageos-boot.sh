#!/bin/sh
set -eu

# Run the same bounded LineageOS boot probe used during Pinecone bring-up and
# print a compact comparison record. This deliberately does not stop on the
# first framebuffer: lean-image work is measured by Android storage and init
# progress after the kernel display appears.

artifact_dir="${1:-artifacts/lineageos-virtio-arm64only-v2026.10.18}"
report_path="${2:-${TMPDIR:-/tmp}/arm64viz-lineage-benchmark.json}"
arm64viz_cli="${ARM64VIZ_CLI:-.build/release/arm64viz}"
duration_ms="${LINEAGE_BENCHMARK_DURATION_MS:-60000}"
memory_mib="${LINEAGE_BENCHMARK_MEMORY_MIB:-1024}"
virtual_cpus="${LINEAGE_BENCHMARK_VCPUS:-4}"

case "$duration_ms:$memory_mib:$virtual_cpus" in
  *[!0-9:]* | *::* | :* | *:)
    echo "benchmark settings must be positive integers" >&2
    exit 2
    ;;
esac

for value in "$duration_ms" "$memory_mib" "$virtual_cpus"; do
  if [ "$value" -le 0 ]; then
    echo "benchmark settings must be positive integers" >&2
    exit 2
  fi
done

boot_image="$artifact_dir/boot.img"
vendor_boot_image="$artifact_dir/vendor_boot.img"
system_disk="${LINEAGE_BENCHMARK_SYSTEM_DISK:-}"
userdata_disk="${LINEAGE_BENCHMARK_USERDATA_DISK:-}"
if [ -z "$system_disk" ]; then
  for name in vda-unencrypted-preexpanded-complete-all-fontfix2-nobootanim.raw vda-arm64viz.raw vda.raw; do
    if [ -f "$artifact_dir/$name" ]; then
      system_disk="$artifact_dir/$name"
      break
    fi
  done
fi
if [ -z "$userdata_disk" ]; then
  for name in vdb-arm64viz.raw vdb.raw; do
    if [ -f "$artifact_dir/$name" ]; then
      userdata_disk="$artifact_dir/$name"
      break
    fi
  done
fi

for path in "$arm64viz_cli" "$boot_image" "$vendor_boot_image" \
  "$system_disk" "$userdata_disk"; do
  if [ ! -f "$path" ]; then
    echo "required benchmark input is missing: $path" >&2
    exit 2
  fi
done

mkdir -p "$(dirname "$report_path")"

# Match the product default; callers can still opt into assembly with =1.
PINECONE_ASSEMBLY_EXECUTOR="${PINECONE_ASSEMBLY_EXECUTOR:-0}" \
  "$arm64viz_cli" run-lineageos-trace "$boot_image" \
  --vendor-boot "$vendor_boot_image" \
  --disk "$system_disk" \
  --secondary-disk "$userdata_disk" \
  --memory-mib "$memory_mib" \
  --vcpus "$virtual_cpus" \
  --max-steps 20000000000 \
  --total-wall-clock-budget-ms "$duration_ms" \
  --wall-clock-budget-ms 20 \
  --exception-storm-threshold 0 \
  --trace-depth 0 \
  --mmio-trace-depth 0 \
  --sysreg-trace-depth 0 > "$report_path"

python3 - "$report_path" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    report = json.load(stream)

elapsed_ms = max(1, int(report.get("wallClockElapsedMilliseconds", 0)))
primary = int(report.get("executedSteps") or 0)
secondary = int(report.get("secondaryExecutedSteps") or 0)
aggregate_mips = (primary + secondary) / elapsed_ms / 1000
block_requests = int(report.get("virtioBlockRequests") or 0)
display_generation = int(report.get("displayGeneration") or 0)
error = report.get("error")

print(f"report={path}")
print(f"elapsed_ms={elapsed_ms}")
print(f"aggregate_mips={aggregate_mips:.2f}")
print(f"primary_steps={primary}")
print(f"secondary_steps={secondary}")
print(f"virtio_block_requests={block_requests}")
print(f"display_generation={display_generation}")
print(f"stop_reason={report.get('stopReason', '-')}")

failures = []
if error:
    failures.append(f"runtime error: {error}")
if secondary == 0:
    failures.append("secondary vCPUs never executed")
if block_requests == 0:
    failures.append("Android never issued a VirtIO block request")
if display_generation <= 1:
    failures.append("guest display never advanced past its initial generation")
if failures:
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    raise SystemExit(1)
PY
