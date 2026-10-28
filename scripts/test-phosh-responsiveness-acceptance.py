#!/usr/bin/env python3
"""Synthetic validation tests only; no Simulator, guest, builds, or UI input."""
import copy
import importlib.util
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name("phosh-interaction-acceptance.py")
SPEC = importlib.util.spec_from_file_location("acceptance", SCRIPT)
acceptance = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(acceptance)


def metrics_fixture():
    elapsed = {"guestExecutionStarted": 0, "shellPrompt": 10, "firstVisibleFrame": 15,
               "interactiveWorkloadStarted": 20, "interactiveWorkloadReady": 30,
               "applicationLaunchRequested": 40, "applicationSurfacePresented": 50}
    execution = {name: {"primaryNativeSteps": 100, "secondaryNativeSteps": 50,
                        "primaryFallbackSteps": 0, "secondaryFallbackSteps": 0}
                 for name in elapsed if name != "guestExecutionStarted"}
    return {"elapsedMilliseconds": elapsed, "executionAtMilestones": execution,
            "framePipeline": {"frameSampleCount": 10}, "touchSampleCount": 0,
            "graphics": {"virtioGPU": dict.fromkeys(acceptance.GPU_FAILURES, 0)},
            "interactions": [], "guestGraphics": []}


def sample(generation=1, total=100):
    return {"generation": generation, "queueToDeviceMilliseconds": 1,
            "deviceToCommitMilliseconds": total - 4, "commitToPublishMilliseconds": 1,
            "publishToPresentMilliseconds": 2, "totalMilliseconds": total}


class AcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pinecone-owner6-acceptance-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.identity = {"rootfsSha256": "a" * 64, "kernelSha256": "b" * 64, "appSha256": "c" * 64,
                         "configuration": {"vcpuCount": 2, "swiftFallbackEnabled": False,
                             "guardrailProfile": "unchanged", "host": "synthetic-test-only",
                             "viewport": [480, 1024], "inputDriver": "synthetic ordinary-pointer",
                             "profiling": {"interactionTrace": True}, "backgroundWork": "none",
                             "appId": "org.test.App", "scrollTarget": "test list",
                             "keyboardTarget": "empty test field", "launchMethod": "phosh-icon",
                             "launchEnvironment": {"session": "Phosh", "envEvidence": "synthetic"},
                             "imageState": "persisted_user_state"}}
        self.manifest = acceptance.make_plan(self.identity)
        self.manifest["runId"] = "synthetic-run-1"
        self.manifest["requirements"]["p95BudgetsMs"] = dict.fromkeys(acceptance.COHORTS, 2000)
        (self.root / "runtime.log").write_text("steps=100 stop=yielded\nnative 100 fallback 0 secondary-fallback=0\n")
        (self.root / "uart.log").write_text("synthetic healthy guest\n")
        (self.root / "input.json").write_text('{"synthetic":true}\n')
        (self.root / "before.txt").write_text("synthetic before-state evidence\n")
        (self.root / "process.txt").write_text("synthetic process-state evidence\n")
        for index, attempt in enumerate(self.manifest["attempts"]):
            base = index * 10000
            cohort = attempt["cohort"]
            attempt.update({"clockId": "collector-1", "startedAtMs": base + 100,
                            "finishedAtMs": base + 9000})
            for label, at in (("before", base), ("after", base + 9500)):
                name = f"{index}-{label}"
                self.write_json(name + ".json", metrics_fixture())
                self.manifest["captures"].append({"id": name, "epoch": "vm-1",
                    "clockId": "collector-1", "capturedAtMs": at, "metrics": name + ".json",
                    "runtimeLog": "runtime.log", "uartLog": "uart.log"})
                attempt[label + "Capture"] = name
            input_record = attempt["input"]
            input_record["evidence"] = "input.json"
            if cohort == "unlock-full" or cohort.startswith("scroll-"):
                name = "fullUnlock" if cohort == "unlock-full" else (
                    "shortSwipe" if cohort == "scroll-short" else "longSwipe")
                spec = acceptance.protocol()[name]
                input_record.update({"durationMs": sum(spec["durationRangeMs"]) / 2,
                    "start": spec["start"], "end": spec["end"], "continuous": True, "moveSampleCount": 20})
            input_record["completedAtMs"] = attempt["startedAtMs"] + input_record.get("durationMs", 400)
            evidence = f"{index}-after.txt"
            (self.root / evidence).write_text(f"synthetic after-state evidence for {index}\n")
            attempt["observation"].update({"status": "pass", "observer": "synthetic test",
                "beforeState": "assertion absent", "afterState": "assertion present",
                "isolated": True, "noInterveningInput": True, "resetObserved": False,
                "beforeEvidence": "before.txt", "afterEvidence": evidence,
                "timing": {"source": "timestamped-semantic-observation", "clockId": "collector-1",
                           "lastAbsentAtMs": base + 1000, "firstPresentAtMs": base + 1100}})
            if cohort.startswith("app-"):
                attempt["input"]["launchMethod"] = "phosh-icon"
                attempt["precondition"] = {"appId": "org.test.App", "evidence": "process.txt",
                    "state": "process-absent" if cohort == "app-cold" else "same-process-resident",
                    "processIdentity": "synthetic PID/start or absence evidence", "coldState": "cold_process"}
            else:
                attempt["precondition"]["state"] = (
                    "locked" if cohort == "unlock-full" else
                    "scrollable-content" if cohort.startswith("scroll-") else "editable-field")

    def write_json(self, name, value):
        (self.root / name).write_text(json.dumps(value) + "\n")

    def change_metrics(self, change, name="0-before.json"):
        path = self.root / name
        data = json.loads(path.read_text())
        change(data)
        self.write_json(name, data)

    def report(self):
        return acceptance.validate(self.manifest, self.root)

    def assert_error(self, code):
        report = self.report()
        self.assertEqual(report["verdict"], "fail")
        self.assertIn(code, [e["code"] for e in report["errors"]], report["errors"])
        return report

    def cli(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *map(str, args)], text=True,
                              capture_output=True, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})

    def test_complete_synthetic_semantic_evidence(self):
        result = self.report()
        self.assertEqual(result["errors"], [])
        self.assertEqual(result["verdict"], "pass")
        self.assertEqual(len(result["attempts"]), 60)
        self.assertEqual(result["cohorts"]["unlock-full"]["validObservedSamples"], 10)
        self.assertNotIn("unlock-short", result["cohorts"])
        self.assertEqual(result["cohorts"]["keyboard"]["semanticUpperBoundLatency"]["p95Ms"], 1000)
        self.assertEqual(result["attempts"][0]["inputDistanceViewportHeights"], .96)

    def test_52_second_unrelated_frame_retains_raw_provenance(self):
        self.change_metrics(lambda d: d.update(interactions=[sample(90, 52369.294125)]))
        report = self.report()
        self.assertEqual(report["verdict"], "pass", report["errors"])
        retained = report["runtimeDiagnosticSamples"][0]
        self.assertEqual(retained["classification"], "expired")
        self.assertEqual(retained["raw"]["totalMilliseconds"], 52369.294125)
        self.assertEqual(retained["provenance"][0]["metrics"], "0-before.json")
        self.assertIn(str((self.root / "0-before.json").resolve()), report["evidenceSha256"])
        self.assertEqual(report["cohorts"]["unlock-full"]["semanticUpperBoundLatency"]["maxMs"], 1000)

    def test_no_semantic_observation_cannot_pass_with_many_frames(self):
        for attempt in self.manifest["attempts"]:
            attempt["observation"] = {"status": "not_observed"}
        self.change_metrics(lambda d: d.update(interactions=[sample(x) for x in range(100)]))
        report = self.assert_error("functional_failure")
        self.assertEqual(report["cohorts"]["unlock-full"]["validObservedSamples"], 0)

    def test_empty_manifest_fails_clearly(self):
        self.manifest = {}
        self.assert_error("missing_metrics")

    def test_missing_milestone_or_fallback_counter_rejected(self):
        self.change_metrics(lambda d: d["elapsedMilliseconds"].pop("interactiveWorkloadReady"))
        self.assert_error("missing_milestone")
        self.change_metrics(lambda d: d["executionAtMilestones"]["shellPrompt"].pop("secondaryFallbackSteps"))
        self.assert_error("incomplete_metrics")

    def test_fallback_counters_and_runtime_log_rejected(self):
        self.change_metrics(lambda d: d["executionAtMilestones"]["shellPrompt"].update(secondaryFallbackSteps=1))
        self.assert_error("fallback")
        (self.root / "runtime.log").write_text("native 100 fallback 0 secondary-fallback=3\n")
        self.assert_error("fallback")

    def test_missing_final_execution_counters_rejected(self):
        (self.root / "runtime.log").write_text("steps=100 stop=yielded\n")
        self.assert_error("incomplete_metrics")

    def test_crash_and_graphics_failure_rejected(self):
        (self.root / "uart.log").write_text("Kernel panic - not syncing\n")
        self.assert_error("crash")
        self.change_metrics(lambda d: d["graphics"]["virtioGPU"].update(paravirtualFinishFailures=1))
        self.assert_error("graphics_failure")

    def test_accessibility_long_swipe_not_normal_unlock(self):
        self.manifest["attempts"][0]["input"]["method"] = "accessibility-action"
        self.assert_error("nonordinary_input")

    def test_canonical_unlock_requires_full_travel_and_continuous_contact(self):
        self.manifest["attempts"][0]["input"]["end"] = [.5, .35]
        self.assert_error("input_protocol")
        self.manifest["attempts"][0]["input"]["end"] = [.5, .02]
        self.manifest["attempts"][0]["input"]["continuous"] = False
        self.assert_error("input_protocol")

    def test_short_unlock_not_mandatory_nor_functional_regression(self):
        diagnostic = copy.deepcopy(self.manifest["attempts"][0])
        # Add the optional diagnostic at the end on a separate collector clock.
        diagnostic.update(id="diagnostic-short", cohort="unlock-short", clockId="diagnostic-clock")
        diagnostic["input"].update(durationMs=200, start=[.5, .85], end=[.5, .35], completedAtMs=300)
        diagnostic["observation"].update(status="fail", afterState="still locked", afterEvidence="diag.txt")
        diagnostic["observation"].pop("timing")
        (self.root / "diag.txt").write_text("synthetic optional diagnostic remains locked\n")
        for label in ("before", "after"):
            capture = copy.deepcopy(self.manifest["captures"][0 if label == "before" else 1])
            capture.update(id="diag-" + label, epoch="diagnostic-epoch", clockId="diagnostic-clock")
            self.manifest["captures"].append(capture)
            diagnostic[label + "Capture"] = capture["id"]
        self.manifest["attempts"].append(diagnostic)
        report = self.report()
        self.assertEqual(report["errors"], [])
        self.assertEqual(report["attempts"][-1]["latency"]["classification"], "diagnostic-no-unlock")

    def test_mixed_clocks_or_overlapping_inputs_rejected(self):
        self.manifest["attempts"][0]["observation"]["timing"]["clockId"] = "guest-clock"
        self.assert_error("invalid_correlation")
        self.manifest["attempts"][1]["startedAtMs"] = 200
        self.assert_error("invalid_correlation")

    def test_reset_crossing_attempt_rejected(self):
        self.manifest["captures"][1]["epoch"] = "vm-reset"
        self.assert_error("reset")

    def test_unannounced_reset_and_reused_generation_rejected(self):
        self.change_metrics(lambda d: d["elapsedMilliseconds"].update(shellPrompt=9), "0-after.json")
        self.assert_error("reset")
        self.change_metrics(lambda d: d.update(interactions=[sample(1, 100)]), "0-before.json")
        self.change_metrics(lambda d: d.update(interactions=[sample(1, 200)]), "0-after.json")
        report = self.assert_error("invalid_correlation")
        self.assertEqual(len(report["runtimeDiagnosticSamples"]), 2)

    def test_nonfinite_negative_boolean_and_stage_sum_mismatch_rejected(self):
        for value in (-1, True, float("nan")):
            with self.subTest(value=value):
                self.change_metrics(lambda d: d.update(interactions=[sample(1, value)]))
                self.assert_error("invalid_json" if isinstance(value, float) and math.isnan(value) else "invalid_correlation")
        self.change_metrics(lambda d: d.update(interactions=[{**sample(), "totalMilliseconds": 101}]))
        self.assert_error("invalid_correlation")

    def test_semantic_expiry_is_retained_and_fails_not_trimmed(self):
        timing = self.manifest["attempts"][0]["observation"]["timing"]
        timing["firstPresentAtMs"] = 6100
        report = self.assert_error("expired")
        self.assertEqual(report["attempts"][0]["latency"]["upperBoundMs"], 6000)
        self.assertEqual(report["attempts"][0]["latency"]["classification"], "expired")

    def test_outlier_inside_window_kept_in_p95_and_budget_failure(self):
        self.manifest["attempts"][0]["observation"]["timing"]["firstPresentAtMs"] = 4600
        report = self.assert_error("latency_budget")
        stats = report["cohorts"]["unlock-full"]["semanticUpperBoundLatency"]
        self.assertEqual(stats["count"], 10)
        self.assertEqual(stats["p95Ms"], 4500)

    def test_cold_and_warm_not_pooled(self):
        for attempt in self.manifest["attempts"]:
            if attempt["cohort"] == "app-warm":
                timing = attempt["observation"]["timing"]
                timing.update(lastAbsentAtMs=attempt["startedAtMs"] + 450,
                              firstPresentAtMs=attempt["startedAtMs"] + 500)
        report = self.report()
        self.assertEqual(report["verdict"], "pass")
        self.assertEqual(report["cohorts"]["app-cold"]["semanticUpperBoundLatency"]["p95Ms"], 1000)
        self.assertEqual(report["cohorts"]["app-warm"]["semanticUpperBoundLatency"]["p95Ms"], 500)

    def test_cold_launch_requires_absence_proof(self):
        attempt = next(a for a in self.manifest["attempts"] if a["cohort"] == "app-cold")
        attempt["precondition"]["state"] = "same-process-resident"
        self.assert_error("missing_precondition")

    def test_tty_launch_and_clean_image_claim_not_equivalent_to_cold_process(self):
        attempt = next(a for a in self.manifest["attempts"] if a["cohort"] == "app-cold")
        attempt["input"]["launchMethod"] = "tty-helper"
        self.assert_error("launch_provenance")
        attempt["input"]["launchMethod"] = "phosh-icon"
        attempt["precondition"]["coldState"] = "clean_image"
        self.assert_error("launch_provenance")

    def test_launch_environment_and_persistent_image_state_must_match_baseline(self):
        current = self.report()
        for field, value in (("launchMethod", "tty-helper"), ("launchEnvironment", "outside-session-bus"),
                             ("imageState", "clean_image"), ("profiling", {"hotPC": True})):
            baseline = copy.deepcopy(current)
            baseline["runId"] = "other-run"
            baseline["identity"]["configuration"][field] = value
            self.assertIn("mismatched_identity", acceptance.compare(current, baseline)["reasons"])

    def test_missing_samples_and_reused_observation_fail(self):
        self.manifest["attempts"].pop()
        self.assert_error("insufficient_samples")
        self.manifest["attempts"][1]["observation"]["afterEvidence"] = "0-after.txt"
        self.assert_error("reused_observation")

    def test_unset_budget_is_not_a_performance_pass(self):
        self.manifest["requirements"]["p95BudgetsMs"]["unlock-full"] = None
        self.assert_error("missing_budget")

    def test_baseline_mismatches_and_failed_baselines_refuse_comparison(self):
        current = self.report()
        baseline = copy.deepcopy(current)
        baseline["runId"] = "synthetic-baseline"
        self.assertTrue(acceptance.compare(current, baseline)["comparable"])
        for field in ("rootfsSha256", "kernelSha256", "appSha256", "configuration"):
            changed = copy.deepcopy(baseline)
            changed["identity"][field] = "changed"
            self.assertIn("mismatched_identity", acceptance.compare(current, changed)["reasons"])
        baseline["verdict"] = "fail"
        self.assertIn("incomplete_acceptance", acceptance.compare(current, baseline)["reasons"])

    def test_new_attribution_schema_preserved_without_causal_upgrade(self):
        big = 2 ** 63 + 1
        additions = {"inputFrameCorrelation": "unavailable: no shared input/frame identity",
            "inputAttribution": [{"identity": {"epoch": 1, "sequence": big}, "phase": "up",
                "captureNanoseconds": big, "queuedNanoseconds": big + 10,
                "injectedNanoseconds": big + 20, "disposition": "reset"}],
            "attributionCounts": {"queued": 300, "reset": 1}}
        self.change_metrics(lambda d: d.update(additions))
        report = self.report()
        self.assertEqual(report["errors"], [])
        self.assertEqual(report["runtimeDiagnosticSamples"], [])
        self.assertEqual(report["runtimeAttribution"][0]["inputAttribution"][0]["identity"]["sequence"], big)

    def test_new_attribution_invalid_duplicate_identity_fails(self):
        record = {"identity": {"epoch": 1, "sequence": 1}, "queuedNanoseconds": 30,
                  "injectedNanoseconds": 20, "disposition": "injectedUncorrelated"}
        self.change_metrics(lambda d: d.update(inputAttribution=[record, record], attributionCounts={"queued": 2},
            inputFrameCorrelation="unavailable: no shared input/frame identity"))
        self.assert_error("invalid_correlation")

    def test_semantic_state_before_pointer_release_is_not_completion(self):
        timing = self.manifest["attempts"][0]["observation"]["timing"]
        timing.update(lastAbsentAtMs=100, firstPresentAtMs=200)
        self.assert_error("invalid_correlation")

    def test_incomplete_null_metric_objects_fail_without_traceback(self):
        self.change_metrics(lambda d: d.update(elapsedMilliseconds=None, executionAtMilestones=None,
                                              framePipeline=None, interactions=None))
        self.assert_error("invalid_schema")

    def test_cli_baseline_retains_manifest_provenance(self):
        self.write_json("manifest.json", self.manifest)
        baseline = copy.deepcopy(self.manifest)
        baseline["runId"] = "synthetic-baseline"
        self.write_json("baseline.json", baseline)
        output = self.root / "comparison"
        result = self.cli("report", self.root / "manifest.json", "--baseline", self.root / "baseline.json",
                          "--output-dir", output)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads((output / "report.json").read_text())
        self.assertTrue(report["comparison"]["comparable"])
        self.assertEqual(report["baseline"]["runId"], "synthetic-baseline")
        self.assertEqual(len(report["baseline"]["manifestSha256"]), 64)

    def test_cli_report_creates_artifacts_and_refuses_overwrite(self):
        self.write_json("manifest.json", self.manifest)
        output = self.root / "report"
        result = self.cli("report", self.root / "manifest.json", "--output-dir", output)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PASS", (output / "report.md").read_text())
        self.assertEqual(self.cli("report", self.root / "manifest.json", "--output-dir", output).returncode, 2)

    def test_cli_inspect_preserves_bytes_and_never_accepts_profile(self):
        self.change_metrics(lambda d: d.update(interactions=[sample(90, 52369)]))
        output = self.root / "diagnostics"
        result = self.cli("inspect", self.root / "0-before.json", "--output-dir", output)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DIAGNOSTIC ONLY", result.stdout)
        self.assertEqual((output / "profile.raw.json").read_bytes(), (self.root / "0-before.json").read_bytes())
        report = json.loads((output / "diagnostics.json").read_text())
        self.assertFalse(report["validForSemanticLatency"])
        self.assertEqual(report["runtimeDiagnosticSamples"][0]["classification"], "expired")

    def test_cli_rejects_mixed_stdout_duplicate_json_keys_and_nan(self):
        for index, text in enumerate(('launcher output\n{"interactions": []}',
                                      '{"a": 1, "a": 2}', '{"a": NaN}')):
            (self.root / "mixed.json").write_text(text)
            result = self.cli("inspect", self.root / "mixed.json", "--output-dir", self.root / f"bad-{index}")
            self.assertEqual(result.returncode, 2, result.stderr)

    def test_cli_plan_is_incomplete_and_does_not_assume_success(self):
        self.write_json("identity.json", self.identity)
        output = self.root / "plan"
        result = self.cli("plan", "--identity", self.root / "identity.json", "--output-dir", output)
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads((output / "manifest.json").read_text())
        self.assertEqual(len(plan["attempts"]), 60)
        self.assertTrue(all(a["observation"]["status"] == "not_observed" for a in plan["attempts"]))
        result = self.cli("report", output / "manifest.json", "--output-dir", self.root / "incomplete")
        self.assertEqual(result.returncode, 1, result.stderr)


if __name__ == "__main__":
    unittest.main()
