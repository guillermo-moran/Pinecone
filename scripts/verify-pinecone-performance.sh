#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE_ID="${PINECONE_SIMULATOR_UDID:-booted}"
BUNDLE_ID="${PINECONE_BUNDLE_ID:-me.gmoran.pinecone}"
APP_PATH="${PINECONE_APP_PATH:-${ROOT_DIR}/Apps/iOS/MobileOSHost/.DerivedData-touch-regression/Build/Products/Release-iphonesimulator/Pinecone.app}"
RUN_COUNT="${PINECONE_PERFORMANCE_RUNS:-3}"
OUTPUT_DIR="${PINECONE_PERFORMANCE_OUTPUT_DIR:-${ROOT_DIR}/.build/pinecone-performance}"
MAX_TOUCH_P95_MS="${PINECONE_MAX_TOUCH_P95_MS:-0}"
MAX_FRAME_INTERVAL_P95_MS="${PINECONE_MAX_FRAME_INTERVAL_P95_MS:-0}"
MAX_COMMIT_TO_PRESENT_P95_MS="${PINECONE_MAX_COMMIT_TO_PRESENT_P95_MS:-0}"
MAX_FRAME_COW_BYTES="${PINECONE_MAX_FRAME_COW_BYTES:-0}"
BASELINE="${PINECONE_PERFORMANCE_BASELINE:-}"
REGRESSION_RATIO="${PINECONE_PERFORMANCE_REGRESSION_RATIO:-1.10}"

if [[ -z "$BASELINE" || ! -f "$BASELINE" ]]; then
  echo 'Set PINECONE_PERFORMANCE_BASELINE to a measured, known-good JSON report.' >&2
  exit 2
fi
jq -e --argjson ratio "$REGRESSION_RATIO" '
  $ratio >= 1 and .touchSampleCount > 0 and
  .touchLatencyP95Milliseconds > 0 and
  .framePipeline.presentationIntervalP95Milliseconds > 0 and
  .framePipeline.commitToPresentP95Milliseconds > 0
' "$BASELINE" >/dev/null || { echo 'Invalid performance baseline or ratio' >&2; exit 2; }
baseline_limit() {
  jq -r --argjson ratio "$REGRESSION_RATIO" "$1 * \$ratio" "$BASELINE"
}
[[ "$MAX_TOUCH_P95_MS" != 0 ]] || MAX_TOUCH_P95_MS="$(baseline_limit '.touchLatencyP95Milliseconds')"
[[ "$MAX_FRAME_INTERVAL_P95_MS" != 0 ]] || MAX_FRAME_INTERVAL_P95_MS="$(baseline_limit '.framePipeline.presentationIntervalP95Milliseconds')"
[[ "$MAX_COMMIT_TO_PRESENT_P95_MS" != 0 ]] || MAX_COMMIT_TO_PRESENT_P95_MS="$(baseline_limit '.framePipeline.commitToPresentP95Milliseconds')"

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
  # Preserve persistent VM data. Use a separate Simulator for clean-image tests.
  xcrun simctl install "${DEVICE_ID}" "${APP_PATH}"

  PINECONE_PROFILE_APPLICATION_COMMAND='pinecone-launch-settings' \
  PINECONE_PROFILE_AUTO_UNLOCK=1 \
  PINECONE_PROFILE_MIN_INTERACTIONS=10 \
  PINECONE_MAX_READY_PRIMARY_STEPS="${PINECONE_MAX_READY_PRIMARY_STEPS:-0}" \
  PINECONE_MAX_APPLICATION_LATENCY_MS="${PINECONE_MAX_APPLICATION_LATENCY_MS:-0}" \
  PINECONE_SIMULATOR_UDID="${DEVICE_ID}" \
    "${ROOT_DIR}/scripts/profile-pinecone-phosh.sh" > "${result}"

  jq -e '(.interactions | length) >= 10 and .elapsedMilliseconds.applicationSurfacePresented != null' \
    "$result" >/dev/null || { echo 'Missing touch/application samples; run is not verified' >&2; exit 1; }

  check_optional_limit() {
    local limit="$1" filter="$2" label="$3"
    if [[ "$limit" != "0" ]] && ! jq -e --argjson limit "$limit" \
      "$filter != null and $filter <= \$limit" "${result}" >/dev/null; then
      actual="$(jq -r "$filter // \"missing\"" "${result}")"
      echo "${label} regression: ${actual} exceeds ${limit}" >&2
      exit 1
    fi
  }
  check_optional_limit "$MAX_TOUCH_P95_MS" '.touchLatencyP95Milliseconds' \
    'Touch p95 milliseconds'
  check_optional_limit "$MAX_FRAME_INTERVAL_P95_MS" \
    '.framePipeline.presentationIntervalP95Milliseconds' 'Frame interval p95 milliseconds'
  check_optional_limit "$MAX_COMMIT_TO_PRESENT_P95_MS" \
    '.framePipeline.commitToPresentP95Milliseconds' 'Commit-to-present p95 milliseconds'
  check_optional_limit "$MAX_FRAME_COW_BYTES" \
    '.graphics.virtioGPU.frameCopyOnWriteBytes' 'Framebuffer copy-on-write bytes'

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
    ((.elapsedMilliseconds.applicationSurfacePresented -
      .elapsedMilliseconds.applicationLaunchRequested) | tostring) + "ms"
  ' "${result}"
done

echo "All ${RUN_COUNT} Simulator runs met the Pinecone performance gates."
