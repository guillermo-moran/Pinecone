#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE_ID="${PINECONE_SIMULATOR_UDID:-booted}"
BUNDLE_ID="${PINECONE_BUNDLE_ID:-me.gmoran.pinecone}"
APP_PATH="${PINECONE_APP_PATH:-${ROOT_DIR}/Apps/iOS/MobileOSHost/.DerivedData-touch-regression/Build/Products/Release-iphonesimulator/Pinecone.app}"
RUN_COUNT="${PINECONE_PERFORMANCE_RUNS:-3}"
OUTPUT_DIR="${PINECONE_PERFORMANCE_OUTPUT_DIR:-${ROOT_DIR}/.build/pinecone-performance}"

[[ "${RUN_COUNT}" =~ ^[1-9][0-9]*$ ]] || {
  echo "PINECONE_PERFORMANCE_RUNS must be a positive integer" >&2
  exit 2
}
[[ -d "${APP_PATH}" ]] || {
  echo "Release Simulator app is missing: ${APP_PATH}" >&2
  exit 1
}

mkdir -p "${OUTPUT_DIR}"
for run in $(seq 1 "${RUN_COUNT}"); do
  result="${OUTPUT_DIR}/run-${run}.json"
  rm -f "${result}"
  xcrun simctl terminate "${DEVICE_ID}" "${BUNDLE_ID}" >/dev/null 2>&1 || true
  xcrun simctl uninstall "${DEVICE_ID}" "${BUNDLE_ID}" >/dev/null 2>&1 || true
  xcrun simctl install "${DEVICE_ID}" "${APP_PATH}"

  PINECONE_PROFILE_APPLICATION_COMMAND='while [ ! -e /run/user/0/pinecone-settings-prewarm-ready ]; do sleep 1; done; pinecone-launch-settings' \
  PINECONE_PROFILE_AUTO_UNLOCK=1 \
  PINECONE_MAX_READY_PRIMARY_STEPS="${PINECONE_MAX_READY_PRIMARY_STEPS:-1000000000}" \
  PINECONE_MAX_APPLICATION_LATENCY_MS="${PINECONE_MAX_APPLICATION_LATENCY_MS:-3000}" \
  PINECONE_SIMULATOR_UDID="${DEVICE_ID}" \
    "${ROOT_DIR}/scripts/profile-pinecone-phosh.sh" > "${result}"

  jq -r --arg run "${run}" '
    "run \($run): ready=" +
    ((.elapsedMilliseconds.interactiveWorkloadReady / 1000) | tostring) +
    "s primary=" +
    (.executionAtMilestones.interactiveWorkloadReady.primaryNativeSteps | tostring) +
    " secondary=" +
    (.executionAtMilestones.interactiveWorkloadReady.secondarySteps | tostring) +
    " secondary-native=" +
    ((.executionAtMilestones.interactiveWorkloadReady.secondaryNativeSteps // 0) | tostring) +
    " fallback=" +
    ((.executionAtMilestones.interactiveWorkloadReady.primaryFallbackSteps +
      (.executionAtMilestones.interactiveWorkloadReady.secondaryFallbackSteps // 0)) | tostring) +
    " app=" +
    ((.elapsedMilliseconds.applicationFirstVisibleFrame -
      .elapsedMilliseconds.applicationLaunchRequested) | tostring) + "ms"
  ' "${result}"
done

echo "All ${RUN_COUNT} fresh Simulator runs met the Pinecone performance gates."
