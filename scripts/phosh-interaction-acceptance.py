#!/usr/bin/env python3
"""Offline Phosh acceptance planning and reporting; never controls a device."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import sys


COHORTS = {
    "unlock-full": "unlockedHomeVisible",
    "scroll-short": "scrollPositionChanged",
    "scroll-long": "scrollPositionChanged",
    "keyboard": "keyboardVisibleAndTextInserted",
    "app-cold": "expectedAppContentVisible",
    "app-warm": "expectedAppContentVisible",
}
DIAGNOSTIC_COHORTS = {"unlock-short": "unlockedHomeVisible"}
MILESTONES = ("shellPrompt", "firstVisibleFrame", "interactiveWorkloadStarted",
              "interactiveWorkloadReady")
STAGES = ("queueToDeviceMilliseconds", "deviceToCommitMilliseconds",
          "commitToPublishMilliseconds", "publishToPresentMilliseconds")
GPU_FAILURES = ("paravirtualPrepareFailures", "paravirtualNativeFailures",
                "paravirtualFinishFailures", "paravirtualSynchronizationFailures")
CONFIG_FIELDS = ("vcpuCount", "swiftFallbackEnabled", "guardrailProfile", "host",
                 "viewport", "inputDriver", "profiling", "backgroundWork", "appId",
                 "scrollTarget", "keyboardTarget", "launchMethod", "launchEnvironment", "imageState")
FAILURE_LOG = re.compile(
    r"runner-failure=|Kernel panic|segmentation fault|segfault|unsupported instruction|"
    r"uncaught exception|fatal error|assertion failed|Trace/BPT trap|\bcrashed\b|"
    r"^steps=.*\bstop=(?:halted|breakpoint|exception|el0|guestMemoryWrite|uartOutput)\b",
    re.IGNORECASE | re.MULTILINE)


def number(value):
    return (type(value) is int and value >= 0 or
            type(value) is float and math.isfinite(value) and value >= 0)


def integer(value):
    return type(value) is int and value >= 0


def nonempty(value):
    return isinstance(value, str) and bool(value.strip())


def distribution(values):
    """Nearest-rank percentiles; retain outliers and report the whole range."""
    values = sorted(values)
    if not values:
        return {"count": 0}
    return {"count": len(values), "minMs": values[0], "maxMs": values[-1],
            "p50Ms": values[math.ceil(len(values) * .50) - 1],
            "p95Ms": values[math.ceil(len(values) * .95) - 1]}


def parse_json(data):
    def reject(value):
        raise ValueError("non-finite JSON number: " + value)
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate JSON key: " + key)
            result[key] = value
        return result
    return json.loads(data, parse_constant=reject, object_pairs_hook=unique)


def read_json(path):
    return parse_json(path.read_bytes())


def protocol():
    return {
        "version": 1,
        "fullUnlock": {"durationRangeMs": [120, 1200], "start": [.5, .98], "end": [.5, .02]},
        "shortSwipe": {"durationRangeMs": [120, 350], "start": [.5, .85], "end": [.5, .35]},
        "longSwipe": {"durationRangeMs": [650, 1100], "start": [.5, .85], "end": [.5, .15]},
        "coldDefinition": "cold_process; target process absent; filesystem caches and persisted dconf uncontrolled",
        "warmDefinition": "same target process previously presented and still resident",
        "method": "ordinary-pointer; keyboard uses individual on-screen key taps",
        "timing": "same-clock semantic observation upper bounds; no frame-only success",
    }


def make_plan(identity, repetitions=10):
    attempts = []
    # Interleave cohorts; each attempt still requires explicit state preparation.
    for repeat in range(1, repetitions + 1):
        for cohort, assertion in COHORTS.items():
            attempts.append({"id": f"{cohort}-{repeat:02d}", "cohort": cohort,
                             "beforeCapture": None, "afterCapture": None,
                             "clockId": None, "startedAtMs": None, "finishedAtMs": None,
                             "input": {"method": "ordinary-pointer", "evidence": None},
                             "observation": {"status": "not_observed", "assertion": assertion},
                             "precondition": {}})
    return {"schemaVersion": 1, "runId": None, "identity": identity,
            "protocol": protocol(), "requirements": {"minimumPerCohort": repetitions,
                "interactionWindowMs": 5000, "launchWindowMs": 120000,
                "p95BudgetsMs": {cohort: None for cohort in COHORTS}},
            "captures": [], "attempts": attempts}


class Validator:
    def __init__(self, manifest, base):
        self.manifest = manifest
        self.base = Path(base)
        self.errors = []
        self.evidence = {}

    def error(self, code, where, detail):
        self.errors.append({"code": code, "where": where, "detail": detail})

    def artifact(self, name, where):
        if not nonempty(name):
            self.error("missing_evidence", where, "An evidence file is required.")
            return None
        path = (self.base / name).resolve()
        try:
            data = path.read_bytes()
            if not data:
                raise ValueError("empty file")
        except (OSError, ValueError) as error:
            self.error("missing_evidence", where, f"{path}: {error}")
            return None
        digest = hashlib.sha256(data).hexdigest()
        if str(path) in self.evidence and self.evidence[str(path)] != digest:
            self.error("evidence_changed", where, f"{path} changed during validation; use immutable captures.")
        self.evidence[str(path)] = digest
        return data

    def object(self, value, where):
        if not isinstance(value, dict):
            self.error("invalid_schema", where, "Expected an object.")
            return {}
        return value

    def array(self, value, where):
        if not isinstance(value, list):
            self.error("invalid_schema", where, "Expected an array.")
            return []
        return value

    def validate_identity(self):
        identity = self.object(self.manifest.get("identity"), "identity")
        for key in ("rootfsSha256", "kernelSha256", "appSha256"):
            if not isinstance(identity.get(key), str) or not re.fullmatch(r"[0-9a-f]{64}", identity[key]):
                self.error("missing_identity", "identity." + key, "Expected lowercase SHA-256.")
        config = self.object(identity.get("configuration"), "identity.configuration")
        for key in CONFIG_FIELDS:
            if key not in config or config[key] is None or config[key] == "":
                self.error("missing_configuration", key, "Record the exact test configuration.")
        if not integer(config.get("vcpuCount")) or config["vcpuCount"] < 1:
            self.error("missing_configuration", "vcpuCount", "Positive vCPU count required.")
        if config.get("swiftFallbackEnabled") is not False:
            self.error("fallback", "configuration", "Swift instruction fallback must be disabled.")
        if config.get("launchMethod") != "phosh-icon":
            self.error("launch_provenance", "configuration", "Acceptance requires Phosh icon launch, not a TTY helper.")
        if config.get("imageState") not in ("persisted_user_state", "clean_image"):
            self.error("launch_provenance", "configuration", "Distinguish persisted_user_state from clean_image explicitly.")
        return identity

    def metrics(self, raw, where, window):
        metrics = self.object(raw, where)
        metrics = metrics.copy()
        elapsed = self.object(metrics.get("elapsedMilliseconds"), where + ".elapsedMilliseconds")
        execution = self.object(metrics.get("executionAtMilestones"), where + ".executionAtMilestones")
        metrics["elapsedMilliseconds"] = elapsed
        metrics["executionAtMilestones"] = execution
        for name in MILESTONES:
            if not number(elapsed.get(name)) or name not in execution:
                self.error("missing_milestone", where, name)
        if elapsed.get("guestExecutionStarted") != 0:
            self.error("missing_milestone", where, "guestExecutionStarted must be zero.")
        for name, counters in execution.items():
            counters = self.object(counters, where + "." + name)
            for key in ("primaryFallbackSteps", "secondaryFallbackSteps",
                        "primaryNativeSteps", "secondaryNativeSteps"):
                if not integer(counters.get(key)):
                    self.error("incomplete_metrics", where + "." + name, key)
                elif "Fallback" in key and counters[key] != 0:
                    self.error("fallback", where + "." + name, key)
        ordered = [elapsed.get(key) for key in ("shellPrompt", "interactiveWorkloadStarted",
                                               "interactiveWorkloadReady")]
        if all(number(x) for x in ordered) and ordered != sorted(ordered):
            self.error("invalid_milestone_order", where, "Shell/start/ready order is invalid.")
        graphics = self.object(metrics.get("graphics"), where + ".graphics")
        gpu = self.object(graphics.get("virtioGPU"), where + ".graphics.virtioGPU")
        for key in GPU_FAILURES:
            if not integer(gpu.get(key)):
                self.error("incomplete_metrics", where, key)
            elif gpu[key] != 0:
                self.error("graphics_failure", where, key)
        frame = self.object(metrics.get("framePipeline"), where + ".framePipeline")
        metrics["framePipeline"] = frame
        if not integer(frame.get("frameSampleCount")) or frame["frameSampleCount"] == 0:
            self.error("missing_milestone", where, "No recorded presentation (not a semantic assertion).")
        if not integer(metrics.get("touchSampleCount")):
            self.error("incomplete_metrics", where, "touchSampleCount required; zero is valid.")
        interactions = self.array(metrics.get("interactions"), where + ".interactions")
        samples = []
        seen = set()
        for index, sample in enumerate(interactions):
            sample = self.object(sample, f"{where}.interactions[{index}]")
            generation = sample.get("generation")
            values = [sample.get(key) for key in STAGES + ("totalMilliseconds",)]
            status = "uncorrelated"
            if (not integer(generation) or generation in seen or
                    not all(number(value) for value in values)):
                status = "invalid"
                self.error("invalid_correlation", where, f"Malformed/duplicate sample at index {index}.")
            elif not math.isclose(sum(values[:-1]), values[-1], abs_tol=.01, rel_tol=1e-6):
                status = "invalid"
                self.error("invalid_correlation", where, f"Stage sum mismatch for generation {generation}.")
            elif values[-1] > window:
                status = "expired"
            if integer(generation):
                seen.add(generation)
            samples.append({"generation": generation, "classification": status, "raw": sample})
        if "inputAttribution" in metrics:
            records = self.array(metrics["inputAttribution"], where + ".inputAttribution")
            counts = self.object(metrics.get("attributionCounts"), where + ".attributionCounts")
            if not nonempty(metrics.get("inputFrameCorrelation")):
                self.error("incomplete_metrics", where, "inputFrameCorrelation required with inputAttribution.")
            for name, count in counts.items():
                if not integer(count):
                    self.error("incomplete_metrics", where + ".attributionCounts", name)
            identities = set()
            for record in records:
                record = self.object(record, where + ".inputAttribution[]")
                identity = self.object(record.get("identity"), where + ".inputAttribution[].identity")
                epoch, sequence = identity.get("epoch"), identity.get("sequence")
                if not integer(epoch) or not integer(sequence):
                    self.error("invalid_correlation", where, "Invalid input epoch/sequence.")
                elif (epoch, sequence) in identities:
                    self.error("invalid_correlation", where, "Duplicate bounded input identity.")
                else:
                    identities.add((epoch, sequence))
                if record.get("disposition") not in ("queued", "injectedUncorrelated", "coalesced",
                        "droppedMotion", "rejected", "expiredUncorrelated", "reset", "sequenceWrap"):
                    self.error("incomplete_metrics", where, "Unknown attribution disposition.")
                for field in ("queuedNanoseconds", "captureNanoseconds", "injectedNanoseconds"):
                    if (field == "queuedNanoseconds" or field in record) and not integer(record.get(field)):
                        self.error("invalid_correlation", where, "Invalid " + field)
                queued, injected = record.get("queuedNanoseconds"), record.get("injectedNanoseconds")
                if integer(queued) and integer(injected) and injected < queued:
                    self.error("invalid_correlation", where, "Injection predates queue admission.")
                # Dispositions including reset and expiry are diagnostic outcomes,
                # not independently evidence of a failed semantic interaction.
        return metrics, samples

    def captures(self, window):
        captures = {}
        diagnostic_samples = {}
        epochs = {}
        previous = {}
        for index, raw in enumerate(self.array(self.manifest.get("captures"), "captures")):
            item = self.object(raw, f"captures[{index}]")
            key = item.get("id")
            if not nonempty(key) or key in captures:
                self.error("invalid_capture", f"captures[{index}]", "Unique capture id required.")
                continue
            begin = len(self.errors)
            for field in ("epoch", "clockId"):
                if not nonempty(item.get(field)):
                    self.error("invalid_capture", key, field + " required.")
            if not number(item.get("capturedAtMs")):
                self.error("invalid_capture", key, "capturedAtMs required in collector monotonic clock.")
            data = self.artifact(item.get("metrics"), key + ".metrics")
            metrics = {}
            if data:
                try:
                    metrics = parse_json(data)
                except (ValueError, OSError, UnicodeError) as error:
                    self.error("invalid_json", key, str(error))
            metrics, samples = self.metrics(metrics, key, window)
            for field in ("runtimeLog", "uartLog"):
                data = self.artifact(item.get(field), key + "." + field)
                if data:
                    log = data.decode("utf-8", errors="replace")
                    match = FAILURE_LOG.search(log)
                    if match:
                        self.error("crash", key + "." + field, match.group(0))
                    for match in re.finditer(r"\bfallback(?:=|\s+)([\d,]+)", log):
                        if int(match[1].replace(",", "")):
                            self.error("fallback", key + "." + field, match.group(0))
                    if field == "runtimeLog" and (not re.search(r"\bnative [\d,]+ fallback 0\b", log) or
                            not re.search(r"\bsecondary-fallback=0\b", log)):
                        self.error("incomplete_metrics", key, "Final primary/secondary fallback counters missing from runtime log.")
            # Current milestones are write-once; changed/disappearing values imply
            # a reset or capture mixup. A reset must get a new collector epoch.
            epoch = item.get("epoch")
            clock = item.get("clockId")
            if nonempty(epoch) and nonempty(clock) and number(item.get("capturedAtMs")):
                if epoch in epochs and epochs[epoch] != clock:
                    self.error("reset", key, "Epoch clock changed.")
                epochs[epoch] = clock
                prior = previous.get(epoch)
                if prior:
                    if item["capturedAtMs"] <= prior["capturedAtMs"]:
                        self.error("reset", key, "Capture timestamps must increase within an epoch.")
                    for field in ("elapsedMilliseconds", "executionAtMilestones"):
                        for name, value in prior["data"].get(field, {}).items():
                            if metrics.get(field, {}).get(name) != value:
                                self.error("reset", key, f"Write-once {field}.{name} changed/disappeared.")
                    old_count = prior["data"].get("framePipeline", {}).get("frameSampleCount")
                    new_count = metrics.get("framePipeline", {}).get("frameSampleCount")
                    if integer(old_count) and integer(new_count) and new_count < old_count:
                        self.error("reset", key, "Frame sample counter decreased.")
                previous[epoch] = {**item, "data": metrics}
            for sample in samples:
                sample_key = (str(epoch), str(sample["generation"]))
                if sample_key in diagnostic_samples and diagnostic_samples[sample_key]["raw"] != sample["raw"]:
                    self.error("invalid_correlation", key, "Generation reused with different metrics within epoch.")
                provenance = {"captureId": key, "metrics": item.get("metrics")}
                if sample_key in diagnostic_samples and diagnostic_samples[sample_key]["raw"] == sample["raw"]:
                    diagnostic_samples[sample_key]["provenance"].append(provenance)
                else:
                    # Preserve conflicting records too; do not silently overwrite evidence.
                    if sample_key in diagnostic_samples:
                        sample_key = (*sample_key, key)
                    diagnostic_samples[sample_key] = {"epoch": epoch, **sample, "provenance": [provenance]}
            captures[key] = {**item, "data": metrics, "valid": len(self.errors) == begin}
        if not captures:
            self.error("missing_metrics", "captures", "No runtime capture was supplied.")
        return captures, list(diagnostic_samples.values())

    def attempt(self, attempt, captures, requirements, used_evidence):
        key = attempt.get("id")
        cohort = attempt.get("cohort")
        start_errors = len(self.errors)
        result = {"id": key, "cohort": cohort, "functional": "not_observed",
                  "latency": {"classification": "invalid"}}
        if not nonempty(cohort) or cohort not in {**COHORTS, **DIAGNOSTIC_COHORTS}:
            self.error("invalid_cohort", str(key), str(cohort))
            return result
        diagnostic_only = cohort in DIAGNOSTIC_COHORTS
        result["diagnosticOnly"] = diagnostic_only
        before = captures.get(attempt.get("beforeCapture")) if nonempty(attempt.get("beforeCapture")) else None
        after = captures.get(attempt.get("afterCapture")) if nonempty(attempt.get("afterCapture")) else None
        if not before or not after or not before["valid"] or not after["valid"]:
            self.error("invalid_capture", str(key), "Valid before/after captures required.")
        else:
            if before.get("epoch") != after.get("epoch"):
                self.error("reset", key, "Attempt crosses a runtime reset.")
            clock = attempt.get("clockId")
            if clock != before.get("clockId") or clock != after.get("clockId"):
                self.error("invalid_correlation", key, "Attempt and captures use different clocks.")
            times = [before.get("capturedAtMs"), attempt.get("startedAtMs"),
                     attempt.get("finishedAtMs"), after.get("capturedAtMs")]
            if not all(number(t) for t in times) or times != sorted(times) or times[1] == times[2]:
                self.error("invalid_correlation", key, "Attempt must be bounded by its captures.")
        input_record = self.object(attempt.get("input"), str(key) + ".input")
        if input_record.get("method") != "ordinary-pointer":
            self.error("nonordinary_input", key, "Accessibility actions/auto-unlock are diagnostic only.")
        self.artifact(input_record.get("evidence"), str(key) + ".input")
        input_times = [attempt.get("startedAtMs"), input_record.get("completedAtMs"), attempt.get("finishedAtMs")]
        if not all(number(t) for t in input_times) or input_times != sorted(input_times):
            self.error("input_protocol", key, "Record input completion within the attempt window.")
        if cohort == "unlock-full" or cohort.endswith(("-short", "-long")):
            spec = protocol()["fullUnlock" if cohort == "unlock-full" else
                              "shortSwipe" if cohort.endswith("-short") else "longSwipe"]
            duration = input_record.get("durationMs")
            low, high = spec["durationRangeMs"]
            if not number(duration) or not low <= duration <= high:
                self.error("input_protocol", key, f"Swipe duration must be {low}..{high} ms.")
            elif all(number(t) for t in input_times) and not math.isclose(
                    input_times[1] - input_times[0], duration, abs_tol=.01):
                self.error("input_protocol", key, "Swipe duration disagrees with pointer down/up timestamps.")
            if input_record.get("continuous") is not True or not integer(input_record.get("moveSampleCount")) or input_record["moveSampleCount"] < 4:
                self.error("input_protocol", key, "Continuous pointer contact and at least four motion samples required.")
            for endpoint in ("start", "end"):
                point = input_record.get(endpoint)
                if (not isinstance(point, list) or len(point) != 2 or
                        not all(number(x) and x <= 1 for x in point) or
                        any(abs(x - y) > .02 for x, y in zip(point, spec[endpoint]))):
                    self.error("input_protocol", key, f"Normalized {endpoint} must match protocol within 0.02.")
            start_point, end_point = input_record.get("start"), input_record.get("end")
            if (isinstance(start_point, list) and isinstance(end_point, list) and
                    len(start_point) == len(end_point) == 2 and
                    all(number(x) for x in start_point + end_point)):
                result["inputDistanceViewportHeights"] = abs(start_point[1] - end_point[1])
            result["inputDurationMs"] = duration
        observation = self.object(attempt.get("observation"), str(key) + ".observation")
        status = observation.get("status")
        result["functional"] = status if status in ("pass", "fail", "not_observed") else "not_observed"
        if status != "pass" and not diagnostic_only:
            self.error("functional_failure", key, "Expected UI state was not observed.")
        assertion = {**COHORTS, **DIAGNOSTIC_COHORTS}[cohort]
        if observation.get("assertion") != assertion:
            self.error("missing_assertion", key, assertion)
        for field in ("observer", "beforeState", "afterState"):
            if not nonempty(observation.get(field)):
                self.error("missing_observation", key, field)
        for field in ("isolated", "noInterveningInput"):
            if observation.get(field) is not True:
                self.error("invalid_correlation", key, field + " must be explicitly observed.")
        if observation.get("resetObserved") is not False:
            self.error("reset", key, "Explicit no-reset observation required.")
        self.artifact(observation.get("beforeEvidence"), str(key) + ".beforeEvidence")
        after_evidence = observation.get("afterEvidence")
        self.artifact(after_evidence, str(key) + ".afterEvidence")
        if nonempty(after_evidence):
            resolved = str((self.base / after_evidence).resolve())
            if resolved in used_evidence:
                self.error("reused_observation", key, "Each attempt needs its own after-state evidence.")
            used_evidence.add(resolved)
        precondition = self.object(attempt.get("precondition"), str(key) + ".precondition")
        if cohort.startswith("app-"):
            if input_record.get("launchMethod") != "phosh-icon":
                self.error("launch_provenance", key, "Application launch must be a real Phosh icon tap.")
            if cohort == "app-cold" and precondition.get("coldState") != "cold_process":
                self.error("launch_provenance", key, "cold_process is not a claim of clean_image state.")
            if not nonempty(precondition.get("appId")):
                self.error("missing_precondition", key, "Exact app ID required.")
            elif precondition["appId"] != self.identity.get("configuration", {}).get("appId"):
                self.error("missing_precondition", key, "App ID differs from declared workload.")
            expected = "process-absent" if cohort == "app-cold" else "same-process-resident"
            if precondition.get("state") != expected:
                self.error("missing_precondition", key, expected)
            self.artifact(precondition.get("evidence"), str(key) + ".processState")
            if not nonempty(precondition.get("processIdentity")):
                self.error("missing_precondition", key, "Record PID/start identity or absence-check details.")
            # Write-once launch milestones cannot measure repeated launches.
            # They remain required for launch capture health, never reused as timings.
            if after:
                elapsed = after["data"].get("elapsedMilliseconds", {})
                requested = elapsed.get("applicationLaunchRequested")
                presented = elapsed.get("applicationSurfacePresented")
                if not number(requested) or not number(presented) or presented < requested:
                    self.error("missing_milestone", key, "Ordered application request/present milestones required.")
        else:
            required = ("locked" if cohort.startswith("unlock-") else
                        "scrollable-content" if cohort.startswith("scroll-") else "editable-field")
            if precondition.get("state") != required:
                self.error("missing_precondition", key, required)
        if diagnostic_only and status != "pass":
            result["latency"] = {"classification": "diagnostic-no-unlock"}
            result["valid"] = len(self.errors) == start_errors
            result["errors"] = self.errors[start_errors:]
            return result
        timing = self.object(observation.get("timing"), str(key) + ".timing")
        if timing.get("source") != "timestamped-semantic-observation":
            self.error("invalid_correlation", key, "A changed frame is not a semantic result.")
        if timing.get("clockId") != attempt.get("clockId") or not nonempty(timing.get("clockId")):
            self.error("invalid_correlation", key, "Observation and input must share one monotonic clock.")
        timestamps = [attempt.get("startedAtMs"), timing.get("lastAbsentAtMs"),
                      timing.get("firstPresentAtMs"), attempt.get("finishedAtMs")]
        if not all(number(t) for t in timestamps) or timestamps != sorted(timestamps):
            self.error("invalid_correlation", key, "Invalid semantic observation time interval.")
        else:
            if number(input_record.get("completedAtMs")) and timestamps[2] < input_record["completedAtMs"]:
                self.error("invalid_correlation", key, "Semantic completion predates completion of the scripted input.")
            lower = timestamps[1] - timestamps[0]
            upper = timestamps[2] - timestamps[0]
            window = requirements["launchWindowMs" if cohort.startswith("app-") else "interactionWindowMs"]
            result["latency"] = {"classification": "expired" if upper > window else "invalid",
                                 "lowerBoundMs": lower, "upperBoundMs": upper}
            if upper > window:
                self.error("expired", key, f"Semantic result exceeds predeclared {window} ms window.")
        if len(self.errors) == start_errors:
            result["latency"]["classification"] = "observed-upper-bound"
        result["valid"] = len(self.errors) == start_errors
        result["errors"] = self.errors[start_errors:]
        return result

    def run(self):
        if not isinstance(self.manifest, dict):
            self.error("invalid_schema", "manifest", "Expected an object.")
            self.manifest = {}
        if self.manifest.get("schemaVersion") != 1:
            self.error("invalid_schema", "schemaVersion", "Only collector manifest v1 is supported.")
        if not nonempty(self.manifest.get("runId")):
            self.error("missing_identity", "runId", "Unique run ID required.")
        identity = self.validate_identity()
        self.identity = identity
        if self.manifest.get("protocol") != protocol():
            self.error("input_protocol", "protocol", "Use the versioned plan without changing its protocol.")
        requirements = self.object(self.manifest.get("requirements"), "requirements").copy()
        minimum = requirements.get("minimumPerCohort")
        if not integer(minimum) or minimum < 10:
            self.error("insufficient_samples", "minimumPerCohort", "At least ten attempts per cohort required.")
            minimum = 10
        for field, default in (("interactionWindowMs", 5000), ("launchWindowMs", 120000)):
            if not number(requirements.get(field)) or requirements[field] <= 0:
                self.error("invalid_schema", field, "Positive, predeclared correlation window required.")
                requirements[field] = default
        budgets = self.object(requirements.get("p95BudgetsMs"), "p95BudgetsMs")
        for cohort in COHORTS:
            value = budgets.get(cohort)
            if not number(value) or value <= 0:
                self.error("missing_budget", cohort, "Declare a positive P95 upper-bound budget before capture.")
        captures, diagnostics = self.captures(requirements["interactionWindowMs"])
        attempts = []
        seen = set()
        used_evidence = set()
        previous_end = {}
        for index, raw in enumerate(self.array(self.manifest.get("attempts"), "attempts")):
            attempt = self.object(raw, f"attempts[{index}]")
            key = attempt.get("id")
            if not nonempty(key) or key in seen:
                self.error("duplicate_attempt", f"attempts[{index}]", "Unique attempt id required.")
                continue
            seen.add(key)
            outer_start = len(self.errors)
            clock = attempt.get("clockId")
            start, end = attempt.get("startedAtMs"), attempt.get("finishedAtMs")
            if nonempty(clock) and number(start) and number(end):
                if start <= previous_end.get(clock, -1):
                    self.error("invalid_correlation", key, "Attempts overlap or are not in capture order.")
                previous_end[clock] = end
            outer_errors = self.errors[outer_start:]
            result = self.attempt(attempt, captures, requirements, used_evidence)
            if outer_errors:
                result["valid"] = False
                result["latency"]["classification"] = "invalid"
                result["errors"] = outer_errors + result.get("errors", [])
            attempts.append(result)
        cohorts = {}
        for cohort in COHORTS:
            selected = [a for a in attempts if a["cohort"] == cohort]
            valid = [a for a in selected if a.get("valid")]
            if len(valid) < minimum:
                self.error("insufficient_samples", cohort, f"{len(valid)}/{minimum} valid observed attempts.")
            latency = distribution([a["latency"]["upperBoundMs"] for a in valid])
            budget = budgets.get(cohort)
            if latency["count"] and number(budget) and latency["p95Ms"] > budget:
                self.error("latency_budget", cohort, f"P95 upper bound {latency['p95Ms']} ms exceeds {budget} ms.")
            cohorts[cohort] = {"attempted": len(selected), "functionalPasses": sum(
                a["functional"] == "pass" for a in selected), "validObservedSamples": len(valid),
                "semanticUpperBoundLatency": latency, "p95BudgetMs": budget}
        return {"schemaVersion": 1, "runId": self.manifest.get("runId"),
                "verdict": "pass" if not self.errors else "fail", "errors": self.errors,
                "identity": identity, "protocol": self.manifest.get("protocol"),
                "requirements": self.manifest.get("requirements"), "cohorts": cohorts,
                "attempts": attempts, "runtimeDiagnosticSamples": diagnostics,
                "runtimeAttribution": [{"captureId": key, "metrics": capture.get("metrics"),
                    **{field: capture["data"][field] for field in ("inputFrameCorrelation", "inputAttribution",
                       "attributionCounts", "guestFrameStages") if field in capture["data"]}}
                    for key, capture in captures.items()],
                "evidenceSha256": self.evidence,
                "limits": ["Functional results are explicit observer attestations, not image recognition.",
                    "Latency is a semantic observation upper bound, not exact touch-to-photon latency.",
                    "Current runtime frame associations are uncorrelated diagnostics, never gesture success.",
                    "Expired samples and outliers remain in the report; no trimming or speedup claims.",
                    "Native-only assertions cover supplied snapshots/logs, not unobserved execution."]}


def validate(manifest, base):
    return Validator(manifest, base).run()


def compare(current, baseline):
    reasons = []
    for field in ("identity", "protocol", "requirements"):
        if current[field] != baseline[field]:
            reasons.append("mismatched_" + field)
    if current["verdict"] != "pass" or baseline["verdict"] != "pass":
        reasons.append("incomplete_acceptance")
    if current.get("runId") == baseline.get("runId"):
        reasons.append("same_run")
    return {"comparable": not reasons, "reasons": reasons,
            "note": "No automatic speedup claim. Different image/config identities are not a controlled baseline."}


def markdown(report):
    lines = ["# Phosh Interaction Acceptance", "", "Verdict: **" + report["verdict"].upper() + "**", "",
             "Timings below are observer-attested semantic upper bounds, not runtime frame latency.", "",
             "| Cohort | Attempts | Attested pass | Valid samples | P50 ms | P95 ms | Max ms | Budget ms |",
             "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for name, data in report["cohorts"].items():
        latency = data["semanticUpperBoundLatency"]
        values = [name, data["attempted"], data["functionalPasses"], data["validObservedSamples"],
                  latency.get("p50Ms", "n/a"), latency.get("p95Ms", "n/a"), latency.get("maxMs", "n/a"),
                  data["p95BudgetMs"]]
        lines.append("| " + " | ".join(str(v) for v in values) + " |")
    lines += ["", "## Runtime Diagnostics", ""]
    for status in ("uncorrelated", "expired", "invalid"):
        count = sum(s["classification"] == status for s in report["runtimeDiagnosticSamples"])
        lines.append(f"- {status}: {count}; excluded from semantic latency.")
    if report.get("comparison"):
        lines += ["", "Baseline comparison: " + json.dumps(report["comparison"], sort_keys=True)]
    lines += ["", "## Validation Failures", ""]
    lines += [f"- `{e['code']}` ({e['where']}): {e['detail']}" for e in report["errors"]] or ["None."]
    lines += ["", "## Limits", ""] + ["- " + limit for limit in report["limits"]]
    lines += ["", "Full per-attempt results, retained diagnostic samples and evidence hashes are in report.json.", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    plan = commands.add_parser("plan", help="Create an incomplete collection manifest, without device access")
    plan.add_argument("--identity", required=True, type=Path)
    plan.add_argument("--repetitions", default=10, type=int)
    plan.add_argument("--output-dir", required=True, type=Path)
    report = commands.add_parser("report", help="Validate supplied captures and semantic observations")
    report.add_argument("manifest", type=Path)
    report.add_argument("--baseline", type=Path, help="Baseline manifest, independently revalidated")
    report.add_argument("--output-dir", required=True, type=Path)
    inspect = commands.add_parser("inspect", help="Retain and classify one raw profile; never an acceptance pass")
    inspect.add_argument("profile", type=Path)
    inspect.add_argument("--interaction-window-ms", type=float, default=5000)
    inspect.add_argument("--output-dir", required=True, type=Path)
    inspect.add_argument("--provenance", type=Path, help="Launch method/environment and image-state metadata")
    args = parser.parse_args()
    try:
        if args.command == "inspect":
            if not number(args.interaction_window_ms) or args.interaction_window_ms <= 0:
                raise ValueError("positive interaction window required")
            raw = args.profile.read_bytes()
            validator = Validator({}, args.profile.resolve().parent)
            metrics, samples = validator.metrics(parse_json(raw), str(args.profile), args.interaction_window_ms)
            result = {"verdict": "diagnostic-only", "validForSemanticLatency": False,
                      "harnessSha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                      "source": str(args.profile.resolve()), "sourceSha256": hashlib.sha256(raw).hexdigest(),
                      "interactionWindowMs": args.interaction_window_ms,
                      "runtimeDiagnosticSamples": samples, "errors": validator.errors,
                      "runtimeAttribution": {field: metrics[field] for field in ("inputFrameCorrelation",
                          "inputAttribution", "attributionCounts", "guestFrameStages") if field in metrics}}
            if args.provenance:
                provenance_bytes = args.provenance.read_bytes()
                result["launchProvenance"] = parse_json(provenance_bytes)
                result["provenanceSha256"] = hashlib.sha256(provenance_bytes).hexdigest()
            else:
                result["launchProvenance"] = {"status": "unknown; not eligible for baseline comparison"}
            args.output_dir.mkdir(parents=True, exist_ok=False)
            (args.output_dir / "profile.raw.json").write_bytes(raw)
            (args.output_dir / "diagnostics.json").write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
            print(f"DIAGNOSTIC ONLY: {len(samples)} retained samples; {len(validator.errors)} validation failures; {args.output_dir}")
            return 1 if validator.errors else 0
        if args.command == "plan":
            if args.repetitions < 10:
                raise ValueError("at least ten repetitions per cohort required")
            data = make_plan(read_json(args.identity), args.repetitions)
            args.output_dir.mkdir(parents=True, exist_ok=False)
            (args.output_dir / "manifest.json").write_text(json.dumps(data, indent=2) + "\n")
            print(args.output_dir / "manifest.json")
            return 0
        manifest_bytes = args.manifest.read_bytes()
        manifest = parse_json(manifest_bytes)
        result = validate(manifest, args.manifest.resolve().parent)
        result["harnessSha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        result["evidenceSha256"][str(args.manifest.resolve())] = hashlib.sha256(manifest_bytes).hexdigest()
        if args.baseline:
            baseline_bytes = args.baseline.read_bytes()
            baseline = validate(parse_json(baseline_bytes), args.baseline.resolve().parent)
            result["comparison"] = compare(result, baseline)
            result["baseline"] = {"manifest": str(args.baseline.resolve()),
                "manifestSha256": hashlib.sha256(baseline_bytes).hexdigest(),
                "runId": baseline["runId"], "identity": baseline["identity"],
                "cohorts": baseline["cohorts"], "evidenceSha256": baseline["evidenceSha256"]}
            result["baselineErrors"] = baseline["errors"]
            if not result["comparison"]["comparable"]:
                result["verdict"] = "fail"
                result["errors"].append({"code": "invalid_baseline", "where": str(args.baseline),
                                         "detail": ", ".join(result["comparison"]["reasons"])})
        args.output_dir.mkdir(parents=True, exist_ok=False)
        (args.output_dir / "report.json").write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
        (args.output_dir / "report.md").write_text(markdown(result))
        print(f"{result['verdict'].upper()}: {len(result['errors'])} validation failures; {args.output_dir / 'report.md'}")
        return 0 if result["verdict"] == "pass" else 1
    except (OSError, ValueError, TypeError, KeyError, AttributeError, OverflowError) as error:
        print(f"Invalid input/output: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
