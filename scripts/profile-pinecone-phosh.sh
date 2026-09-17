#!/usr/bin/env bash
set -euo pipefail

BUNDLE_ID="${PINECONE_BUNDLE_ID:-me.gmoran.pinecone}"
DEVICE_ID="${PINECONE_SIMULATOR_UDID:-booted}"
TIMEOUT_SECONDS="${PINECONE_PROFILE_TIMEOUT_SECONDS:-180}"
APPLICATION_COMMAND="${PINECONE_PROFILE_APPLICATION_COMMAND:-}"
MAX_READY_PRIMARY_STEPS="${PINECONE_MAX_READY_PRIMARY_STEPS:-0}"
MAX_APPLICATION_LATENCY_MS="${PINECONE_MAX_APPLICATION_LATENCY_MS:-0}"
MIN_INTERACTIONS="${PINECONE_PROFILE_MIN_INTERACTIONS:-0}"
[[ "$MIN_INTERACTIONS" =~ ^[0-9]+$ ]] || {
  echo 'PINECONE_PROFILE_MIN_INTERACTIONS must be a nonnegative integer' >&2
  exit 2
}
INTERACTION_TRACE="${PINECONE_PROFILE_INTERACTION_TRACE:-1}"
[[ "$INTERACTION_TRACE" == 0 || "$INTERACTION_TRACE" == 1 ]] || {
  echo 'PINECONE_PROFILE_INTERACTION_TRACE must be 0 or 1' >&2
  exit 2
}
AUTORUN_COMMAND="PINECONE_INTERACTION_TRACE=${INTERACTION_TRACE} start-pinecone-phosh"
AUTO_UNLOCK="${PINECONE_PROFILE_AUTO_UNLOCK:-0}"
if [[ -n "${APPLICATION_COMMAND}" ]]; then
  # Keep the login shell available for the post-readiness launch request. The
  # session itself is still supervised by pinecone-session-launcher.
  AUTORUN_COMMAND="PINECONE_INTERACTION_TRACE=${INTERACTION_TRACE} start-pinecone-phosh &"
  AUTO_UNLOCK="${PINECONE_PROFILE_AUTO_UNLOCK:-1}"
fi
if [[ "${PINECONE_PROFILE_PIXMAN_DIAGNOSTICS:-0}" == "1" ]]; then
  AUTORUN_COMMAND="PINECONE_PIXMAN_DIAGNOSTICS=1 ${AUTORUN_COMMAND}"
fi

CONTAINER="$(xcrun simctl get_app_container "${DEVICE_ID}" "${BUNDLE_ID}" data)"
METRICS="${CONTAINER}/Library/Caches/pinecone-performance.json"
RUNTIME_LOG="${CONTAINER}/Library/Caches/pinecone-performance.log"
rm -f "${METRICS}" "$RUNTIME_LOG"
xcrun simctl terminate "${DEVICE_ID}" "${BUNDLE_ID}" >/dev/null 2>&1 || true

SIMCTL_CHILD_PINECONE_SIMULATOR_AUTORUN_COMMAND="${AUTORUN_COMMAND}" \
SIMCTL_CHILD_PINECONE_SIMULATOR_AUTO_UNLOCK="${AUTO_UNLOCK}" \
SIMCTL_CHILD_PINECONE_SIMULATOR_POST_READY_COMMAND="${APPLICATION_COMMAND}" \
SIMCTL_CHILD_PINECONE_SIMULATOR_POST_READY_DELAY_MS="${PINECONE_PROFILE_POST_READY_DELAY_MS:-}" \
SIMCTL_CHILD_PINECONE_SIMULATOR_SHOW_DISPLAY=1 \
SIMCTL_CHILD_PINECONE_SIMULATOR_DUMP_UART=1 \
SIMCTL_CHILD_PINECONE_SIMULATOR_WRITE_PERFORMANCE_METRICS=1 \
SIMCTL_CHILD_PINECONE_SIMULATOR_HOT_PC_PROFILE="${PINECONE_PROFILE_HOT_PC:-0}" \
SIMCTL_CHILD_PINECONE_SIMULATOR_DUMP_PERFORMANCE="${PINECONE_PROFILE_DETAILED:-0}" \
SIMCTL_CHILD_PINECONE_VCPU_COUNT="${PINECONE_VCPU_COUNT:-2}" \
SIMCTL_CHILD_PINECONE_EXPERIMENTAL_PARALLEL_VCPU="${PINECONE_EXPERIMENTAL_PARALLEL_VCPU:-1}" \
  xcrun simctl launch "${DEVICE_ID}" "${BUNDLE_ID}" >/dev/null

deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  if [[ -f "$RUNTIME_LOG" ]] && grep -Eq \
    '^runner-failure=|^steps=.* stop=(halted|breakpoint|exception|el0|guestMemoryWrite|uartOutput)' "$RUNTIME_LOG"; then
    cat "$RUNTIME_LOG" >&2
    exit 1
  fi
  if [[ -s "${METRICS}" ]] &&
     jq -e '.elapsedMilliseconds.interactiveWorkloadReady != null and
            .framePipeline.frameSampleCount > 0' "${METRICS}" >/dev/null; then
    if [[ "${AUTO_UNLOCK}" == "1" ]] &&
       ! jq -e '.touchSampleCount > 0' "${METRICS}" >/dev/null; then
      sleep 1
      continue
    fi
    if [[ -n "${APPLICATION_COMMAND}" ]] &&
       ! jq -e '.elapsedMilliseconds.applicationSurfacePresented != null' \
         "${METRICS}" >/dev/null; then
      sleep 1
      continue
    fi
    if ! jq -e --argjson minimum "$MIN_INTERACTIONS" \
      '(.interactions | length) >= $minimum' "$METRICS" >/dev/null; then
      sleep 1
      continue
    fi

    cat "${METRICS}"
    if [[ "$MAX_READY_PRIMARY_STEPS" != 0 ]] && ! jq -e --argjson limit "${MAX_READY_PRIMARY_STEPS}" \
      '.executionAtMilestones.interactiveWorkloadReady.primaryNativeSteps < $limit' \
      "${METRICS}" >/dev/null; then
      actual="$(jq -r \
        '.executionAtMilestones.interactiveWorkloadReady.primaryNativeSteps' \
        "${METRICS}")"
      echo "Phosh readiness regression: primary native instructions ${actual} must be below ${MAX_READY_PRIMARY_STEPS}" >&2
      exit 1
    fi
    if ! jq -e \
      '.executionAtMilestones | all(.[];
        .primaryFallbackSteps == 0 and
        (.secondaryFallbackSteps // 0) == 0)' \
      "${METRICS}" >/dev/null; then
      echo 'Native-only regression: a measured milestone used fallback instructions on at least one vCPU' >&2
      exit 1
    fi
    if [[ -n "${APPLICATION_COMMAND}" && "$MAX_APPLICATION_LATENCY_MS" != 0 ]] &&
       ! jq -e --argjson limit "${MAX_APPLICATION_LATENCY_MS}" \
         '(.elapsedMilliseconds.applicationSurfacePresented -
           .elapsedMilliseconds.applicationLaunchRequested) as $latency |
          $latency >= 0 and $latency <= $limit' \
         "${METRICS}" >/dev/null; then
      latency="$(jq -r \
        '.elapsedMilliseconds.applicationSurfacePresented -
         .elapsedMilliseconds.applicationLaunchRequested' "${METRICS}")"
      echo "Application launch regression: request-to-visible ${latency}ms exceeds ${MAX_APPLICATION_LATENCY_MS}ms" >&2
      exit 1
    fi
    exit 0
  fi
  sleep 1
done

if [[ -n "${APPLICATION_COMMAND}" ]]; then
  echo "Phosh/${APPLICATION_COMMAND} presentation or ${MIN_INTERACTIONS} completed interactions missing after ${TIMEOUT_SECONDS}s" >&2
else
  echo "Phosh did not publish a visible frame within ${TIMEOUT_SECONDS}s" >&2
fi
if [[ -s "${METRICS}" ]]; then
  cat "${METRICS}" >&2
fi
exit 1
