#!/usr/bin/env bash
set -euo pipefail

BUNDLE_ID="${PINECONE_BUNDLE_ID:-me.gmoran.pinecone}"
DEVICE_ID="${PINECONE_SIMULATOR_UDID:-booted}"
TIMEOUT_SECONDS="${PINECONE_PROFILE_TIMEOUT_SECONDS:-180}"

CONTAINER="$(xcrun simctl get_app_container "${DEVICE_ID}" "${BUNDLE_ID}" data)"
METRICS="${CONTAINER}/Library/Caches/pinecone-performance.json"
rm -f "${METRICS}"
xcrun simctl terminate "${DEVICE_ID}" "${BUNDLE_ID}" >/dev/null 2>&1 || true

SIMCTL_CHILD_PINECONE_SIMULATOR_AUTORUN_COMMAND=start-pinecone-phosh \
SIMCTL_CHILD_PINECONE_SIMULATOR_SHOW_DISPLAY=1 \
SIMCTL_CHILD_PINECONE_SIMULATOR_DUMP_UART=1 \
SIMCTL_CHILD_PINECONE_SIMULATOR_WRITE_PERFORMANCE_METRICS=1 \
SIMCTL_CHILD_PINECONE_SIMULATOR_HOT_PC_PROFILE=1 \
SIMCTL_CHILD_PINECONE_SIMULATOR_DUMP_PERFORMANCE=1 \
SIMCTL_CHILD_PINECONE_VCPU_COUNT="${PINECONE_VCPU_COUNT:-2}" \
  xcrun simctl launch "${DEVICE_ID}" "${BUNDLE_ID}" >/dev/null

deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  if [[ -s "${METRICS}" ]] && \
     grep -q 'interactiveWorkloadReady' "${METRICS}" && \
     grep -Eq '"frameSampleCount":[1-9][0-9]*' "${METRICS}"; then
    cat "${METRICS}"
    exit 0
  fi
  sleep 1
done

echo "Phosh did not publish a visible frame within ${TIMEOUT_SECONDS}s" >&2
if [[ -s "${METRICS}" ]]; then
  cat "${METRICS}" >&2
fi
exit 1
