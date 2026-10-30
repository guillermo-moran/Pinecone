#!/usr/bin/env python3
"""Offline harness tests. Every subprocess entry point is blocked by default."""
import argparse
import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "benchmark", Path(__file__).with_name("benchmark-simulator-executors.py"))
BENCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BENCH)
DEVICE = "11111111-2222-3333-4444-555555555555"


def report_for(variant="assembly", ready=True):
    assembly, threaded, memory = BENCH.VARIANTS[variant]
    chain = variant in ("assembly-chain", "assembly-bounded")
    bounded = variant == "assembly-bounded"
    return {
        "elapsedMilliseconds": {"firstVisibleFrame": 100, **({"interactiveWorkloadReady": 2000} if ready else {})},
        "executionAtMilestones": {"interactiveWorkloadReady": {
            "primaryNativeSteps": 10, "primaryFallbackSteps": 0, "secondarySteps": 20,
            "secondaryNativeSteps": 20, "secondaryFallbackSteps": 0}} if ready else {},
        "assemblyExecutorPrimary": {"enabled": assembly, "blocks": 2, "steps": 5 if assembly else 0,
                                    "boundaries": 1, "faults": 0,
                                    "chainEnabled": int(chain), "chainRuns": int(chain),
                                    "chainVisits": 2 if chain else 0, "chainSteps": 4 if chain else 0,
                                    "boundedEnabled": int(bounded), "boundedRuns": int(bounded),
                                    "boundedVisits": 2 if bounded else 0, "boundedSteps": 4 if bounded else 0},
        "threadedPrototypePrimary": {"enabled": threaded, "memoryEnabled": memory,
                                     "blocks": 0, "steps": 3 if threaded else 0},
    }


class HarnessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.seed = self.root / "seed.ext4"
        self.seed.write_bytes(b"immutable seed fixture")
        self.fingerprint = self.root / "fingerprint"
        self.fingerprint.write_text("fingerprint fixture")
        self.app = self.root / "app"
        self.app.mkdir()
        (self.app / "Pinecone").write_bytes(b"same executable")
        self.data = self.root / "data"
        self.data.mkdir()
        self.disk_dir = self.data / "Library/Application Support/Pinecone"
        self.disk_dir.mkdir(parents=True)
        self.cache = self.data / "Library/Caches"
        self.cache.mkdir(parents=True)
        self.output = self.root / "output"
        self.manifest = {
            "cacheDiagnostics": "off",
            "schemaVersion": 1, "seedSHA256": BENCH.digest(self.seed),
            "fingerprintSHA256": BENCH.digest(self.fingerprint),
            "appSHA256": BENCH.digest(self.app / "Pinecone"), "kernelSHA256": "a" * 64,
            "sourceState": "test-only dirty source identity", "compilerFlags": "test-only flags",
            "guestPackages": "test fixture", "hostConditions": "offline test",
            "inputProtocol": "test driver evidence",
        }
        self.manifest_path = self.root / "manifest.json"
        BENCH.write_json(self.manifest_path, self.manifest)
        self.args = argparse.Namespace(output=self.output, seed=self.seed, fingerprint=self.fingerprint,
                                       cache_diagnostics="off",
                                       device=DEVICE, post_ready_command="", timeout=10,
                                       idle_seconds=0, completion_file=None)
        # A missed mock must fail closed, never reach Simulator or the host ps.
        for name in ("check_output", "run", "Popen"):
            blocker = patch.object(BENCH.subprocess, name, side_effect=AssertionError("real subprocess forbidden"))
            blocker.start()
            self.addCleanup(blocker.stop)
        sleeper = patch.object(BENCH.time, "sleep", side_effect=AssertionError("real sleep forbidden"))
        sleeper.start()
        self.addCleanup(sleeper.stop)

    def argv(self):
        return ["--device", DEVICE, "--seed", str(self.seed), "--fingerprint", str(self.fingerprint),
                "--manifest", str(self.manifest_path), "--output", str(self.output),
                "--order", "established", "assembly"]

    def run_fixture(self, variant="assembly", report=None, launch_error=None, sample_error=None,
                    screenshot_error=None):
        self.output.mkdir()
        report = report_for(variant) if report is None else report

        def command(*args, **kwargs):
            if args[0] == "cp":
                Path(args[-1]).write_bytes(Path(args[-2]).read_bytes())
                return ""
            if args[:3] == ("xcrun", "simctl", "launch"):
                if launch_error:
                    raise launch_error
                BENCH.write_json(self.cache / "pinecone-performance.json", report)
                (self.cache / "pinecone-uart.log").write_text("raw UART fixture")
                return "me.gmoran.pinecone: 1234"
            if args[:3] == ("xcrun", "simctl", "io"):
                if screenshot_error:
                    raise screenshot_error
                return ""
            raise AssertionError(args)

        with patch.object(BENCH, "command", side_effect=command), \
                patch.object(BENCH, "terminate_for_restore"), \
                patch.object(BENCH.time, "monotonic", side_effect=[0, 1, 1, 11]), \
                patch.object(BENCH.time, "sleep"), \
                patch.object(BENCH, "sample", side_effect=sample_error,
                             return_value={"cpuSeconds": 1, "rssKiB": 2048, "psCPUPercent": 99}), \
                contextlib.redirect_stdout(io.StringIO()):
            result = BENCH.run_attempt(self.args, self.manifest, 1, variant, self.data, self.app)
        self.assertEqual(BENCH.digest(self.seed), self.manifest["seedSHA256"])
        self.assertEqual(BENCH.read_object(self.output / f"01-{variant}/result.json"), result)
        return result

    def test_all_variants_explicit_and_exclusive(self):
        expected = {"established": ("0", "0", "0"), "threaded": ("0", "1", "0"),
                    "memory": ("0", "1", "1"), "assembly": ("1", "0", "0"),
                    "assembly-chain": ("1", "0", "0"), "assembly-bounded": ("1", "0", "0")}
        for variant, flags in expected.items():
            with self.subTest(variant=variant):
                settings = BENCH.settings_for(variant)
                self.assertEqual(tuple(settings[k] for k in ("PINECONE_ASSEMBLY_EXECUTOR",
                                 "PINECONE_THREADED_PROTOTYPE", "PINECONE_THREADED_MEMORY")), flags)
                self.assertEqual(settings["PINECONE_VCPU_COUNT"], "2")
                self.assertEqual(settings["PINECONE_EXPERIMENTAL_PARALLEL_VCPU"], "1")
                self.assertEqual(settings["PINECONE_ASSEMBLY_CHAINING"],
                                 "1" if variant in ("assembly-chain", "assembly-bounded") else "0")
                self.assertEqual(settings["PINECONE_ASSEMBLY_BOUNDED"],
                                 "1" if variant == "assembly-bounded" else "0")

    def test_bounded_requires_matching_flags_and_subset_counters(self):
        for key in ("boundedEnabled", "boundedRuns", "boundedVisits", "boundedSteps"):
            for invalid in (None, True, -1, 99):
                report = report_for("assembly-bounded")
                report["assemblyExecutorPrimary"][key] = invalid
                with self.assertRaises(ValueError):
                    BENCH.parse_report(report, "assembly-bounded")
        report = report_for("assembly-chain")
        report["assemblyExecutorPrimary"]["boundedSteps"] = 1
        with self.assertRaises(ValueError):
            BENCH.parse_report(report, "assembly-chain")

    def test_enabled_but_unused_bounded_path_is_not_success(self):
        report = report_for("assembly-bounded")
        for key in ("boundedRuns", "boundedVisits", "boundedSteps"):
            report["assemblyExecutorPrimary"][key] = 0
        result = self.run_fixture("assembly-bounded", report=report)
        self.assertIn("no primary bounded execution", result["failure"])

    def test_chain_telemetry_rejects_wrong_flags_and_disabled_work(self):
        for variant in ("assembly", "assembly-chain"):
            report = report_for(variant)
            report["assemblyExecutorPrimary"]["chainEnabled"] ^= 1
            with self.assertRaises(ValueError):
                BENCH.parse_report(report, variant)
        report = report_for("assembly")
        report["assemblyExecutorPrimary"]["chainSteps"] = 1
        with self.assertRaises(ValueError):
            BENCH.parse_report(report, "assembly")

    def test_chain_telemetry_rejects_missing_or_invalid_counters(self):
        for key in ("chainEnabled", "chainRuns", "chainVisits", "chainSteps"):
            for invalid in (None, True, -1):
                report = report_for("assembly-chain")
                report["assemblyExecutorPrimary"][key] = invalid
                with self.assertRaises(ValueError):
                    BENCH.parse_report(report, "assembly-chain")

    def test_environment_scrubs_inherited_flags(self):
        inherited = {"PATH": "/test", "PINECONE_ASSEMBLY_EXECUTOR": "1",
                     "SIMCTL_CHILD_PINECONE_UNKNOWN": "1", "SIMCTL_CHILD_PINECONE_ASSEMBLY_EXECUTOR": "1"}
        environment = BENCH.launch_environment(BENCH.settings_for("established"), inherited)
        self.assertEqual(environment["PATH"], "/test")
        self.assertEqual(environment["SIMCTL_CHILD_PINECONE_ASSEMBLY_EXECUTOR"], "0")
        self.assertNotIn("PINECONE_ASSEMBLY_EXECUTOR", environment)
        self.assertNotIn("SIMCTL_CHILD_PINECONE_UNKNOWN", environment)
        self.assertEqual(inherited["SIMCTL_CHILD_PINECONE_ASSEMBLY_EXECUTOR"], "1")

    def cache_report(self, mode="counts"):
        report = report_for()
        stats = {"compiled": 1, "enabled": int(mode != "off"), "timingEnabled": int(mode == "time"),
                 "publishedHostNanoseconds": 1234567890123456789, "requests": 10, "ownedProgramBytes": 42}
        report.update(assemblyCachePrimary=stats, assemblyCacheSecondaryByVCPU={"1": dict(stats)},
                      assemblyExecutorSecondaryByVCPU={"1": dict(report["assemblyExecutorPrimary"])})
        return report

    def test_cache_settings_explicit_in_every_variant_and_mode(self):
        for variant in BENCH.VARIANTS:
            for mode, value in BENCH.CACHE_DIAGNOSTICS.items():
                settings = BENCH.settings_for(variant, cache_diagnostics=mode)
                env = BENCH.launch_environment(settings, {"SIMCTL_CHILD_PINECONE_ASSEMBLY_CACHE_DIAGNOSTICS": "time"})
                self.assertEqual(env["SIMCTL_CHILD_PINECONE_ASSEMBLY_CACHE_DIAGNOSTICS"], value)
            self.assertEqual(BENCH.settings_for(variant)["PINECONE_ASSEMBLY_CACHE_DIAGNOSTICS"], "0")

    def test_owner_telemetry_preserved_exactly_with_string_ids_and_timestamps(self):
        for mode in BENCH.CACHE_DIAGNOSTICS:
            report = self.cache_report(mode)
            parsed = BENCH.parse_report(report, "assembly", mode)
            for key in BENCH.OWNER_TELEMETRY:
                self.assertEqual(parsed[key], report[key])

    def test_requested_diagnostics_require_compiled_enabled_and_timing_on_each_cpu(self):
        for mode in ("counts", "time"):
            for location in ("primary", "secondary"):
                for field in ("compiled", "enabled", "timingEnabled"):
                    with self.subTest(mode=mode, location=location, field=field):
                        report = self.cache_report(mode)
                        stats = report["assemblyCachePrimary"] if location == "primary" else report["assemblyCacheSecondaryByVCPU"]["1"]
                        stats[field] = 1 - stats[field]
                        with self.assertRaisesRegex(ValueError, "instrumentation"):
                            BENCH.parse_report(report, "assembly", mode)

    def test_requested_diagnostics_refuse_missing_owner_records(self):
        for key in ("assemblyCachePrimary", "assemblyCacheSecondaryByVCPU"):
            report = self.cache_report()
            del report[key]
            with self.assertRaisesRegex(ValueError, "missing"):
                BENCH.parse_report(report, "assembly", "counts")
        report = self.cache_report()
        report["assemblyCacheSecondaryByVCPU"] = {}
        with self.assertRaises(ValueError):
            BENCH.parse_report(report, "assembly", "counts")

    def test_clean_run_rejects_enabled_diagnostics(self):
        with self.assertRaisesRegex(ValueError, "instrumentation"):
            BENCH.parse_report(self.cache_report(), "assembly")

    def test_manifest_diagnostics_mismatch_rejected_before_any_subprocess(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            BENCH.main(self.argv() + ["--plan-only", "--cache-diagnostics", "counts"])
        self.assertFalse(self.output.exists())

    def test_attribution_plan_declares_instrumentation(self):
        self.manifest["cacheDiagnostics"] = "time"
        BENCH.write_json(self.manifest_path, self.manifest)
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(BENCH.main(self.argv() + ["--plan-only", "--cache-diagnostics", "time"]), 0)
        plan = json.loads(output.getvalue())
        self.assertEqual(plan["instrumentation"], {"cacheDiagnostics": "time", "cohortKind": "attribution"})
        self.assertEqual(plan["manifest"]["cacheDiagnostics"], "time")

    def test_attribution_run_preserves_owner_journal_and_summary(self):
        self.args.cache_diagnostics = "counts"
        report = self.cache_report()
        result = self.run_fixture(report=report)
        self.assertIsNone(result["failure"])
        self.assertEqual(result["instrumentation"]["cohortKind"], "attribution")
        journal = (self.output / "01-assembly/owner-telemetry.jsonl").read_text().splitlines()
        for key in BENCH.OWNER_TELEMETRY:
            self.assertEqual(json.loads(journal[0])[key], report[key])
            self.assertEqual(result[key], report[key])

    def test_uncompiled_attribution_failure_retains_telemetry(self):
        self.args.cache_diagnostics = "counts"
        report = self.cache_report()
        report["assemblyCachePrimary"]["compiled"] = 0
        result = self.run_fixture(report=report)
        self.assertIn("instrumentation", result["failure"])
        self.assertTrue((self.output / "01-assembly/owner-telemetry.jsonl").exists())

    def test_manifest_round_trip_and_identity(self):
        self.assertEqual(BENCH.read_manifest(self.manifest_path), self.manifest)
        BENCH.verify_identity(self.seed, self.fingerprint, self.manifest, self.app / "Pinecone")

    def test_manifest_rejects_missing_provenance_or_hashes(self):
        for key in self.manifest:
            with self.subTest(key=key):
                bad = dict(self.manifest)
                del bad[key]
                BENCH.write_json(self.manifest_path, bad)
                with self.assertRaises(ValueError):
                    BENCH.read_manifest(self.manifest_path)

    def test_manifest_rejects_malformed_json_and_non_object(self):
        for raw in ("{", "[]", '{"schemaVersion": 2}'):
            self.manifest_path.write_text(raw)
            with self.assertRaises(ValueError):
                BENCH.read_manifest(self.manifest_path)

    def test_identity_drift_rejected(self):
        for key in ("seedSHA256", "fingerprintSHA256", "appSHA256"):
            with self.subTest(key=key):
                bad = {**self.manifest, key: "0" * 64}
                with self.assertRaisesRegex(ValueError, key):
                    BENCH.verify_identity(self.seed, self.fingerprint, bad, self.app / "Pinecone")

    def test_report_all_modes_and_both_vcpus(self):
        for variant in BENCH.VARIANTS:
            parsed = BENCH.parse_report(report_for(variant), variant)
            self.assertEqual(parsed["combinedNativeStepsAtReady"], 30)
            self.assertEqual(parsed["readyCounters"]["secondaryNativeSteps"], 20)
            self.assertIsNone(parsed["assemblyExecutorSecondary"])
            self.assertEqual(parsed["guestReadySeconds"], 2)
            self.assertEqual(parsed["firstVisibleFrameSeconds"], 0.1)

    def test_first_frame_is_not_readiness(self):
        parsed = BENCH.parse_report(report_for(ready=False), "assembly")
        self.assertIsNone(parsed["guestReadySeconds"])
        self.assertIsNone(parsed["readyCounters"])

    def test_report_rejects_missing_secondary_counters(self):
        report = report_for()
        del report["executionAtMilestones"]["interactiveWorkloadReady"]["secondaryNativeSteps"]
        with self.assertRaisesRegex(ValueError, "secondary"):
            BENCH.parse_report(report, "assembly")

    def test_report_rejects_missing_or_wrong_flags_and_stats(self):
        for key, field in (("assemblyExecutorPrimary", "enabled"),
                           ("threadedPrototypePrimary", "memoryEnabled"),
                           ("assemblyExecutorPrimary", "faults")):
            report = report_for()
            del report[key][field]
            with self.assertRaises(ValueError):
                BENCH.parse_report(report, "assembly")
        with self.assertRaises(ValueError):
            BENCH.parse_report(report_for("established"), "assembly")

    def test_report_rejects_nonfinite_and_negative_times(self):
        for value in (float("nan"), float("inf"), -1, True, "2"):
            report = report_for()
            report["elapsedMilliseconds"]["firstVisibleFrame"] = value
            with self.assertRaises(ValueError):
                BENCH.parse_report(report, "assembly")

    def test_disabled_executor_steps_rejected(self):
        report = report_for("established")
        report["assemblyExecutorPrimary"]["steps"] = 1
        with self.assertRaisesRegex(ValueError, "disabled executor"):
            BENCH.parse_report(report, "established")

    def test_safe_paths(self):
        self.assertEqual(BENCH.validate_paths(self.seed, self.fingerprint, self.data, self.output),
                         (self.disk_dir.resolve(), self.cache.resolve()))

    def test_seed_inside_container_rejected(self):
        seed = self.disk_dir / "seed"
        seed.write_bytes(b"test")
        with self.assertRaises(ValueError):
            BENCH.validate_paths(seed, self.fingerprint, self.data, self.output)

    def test_symlink_target_rejected(self):
        (self.disk_dir / "rootfs.ext4").symlink_to(self.seed)
        with self.assertRaisesRegex(ValueError, "unsafe"):
            BENCH.validate_paths(self.seed, self.fingerprint, self.data, self.output)

    def test_hardlinked_seed_target_rejected(self):
        (self.disk_dir / "rootfs.ext4").hardlink_to(self.seed)
        with self.assertRaisesRegex(ValueError, "aliases"):
            BENCH.validate_paths(self.seed, self.fingerprint, self.data, self.output)

    def test_output_in_container_rejected(self):
        with self.assertRaises(ValueError):
            BENCH.validate_paths(self.seed, self.fingerprint, self.data, self.data / "output")

    def test_plan_only_never_calls_subprocess_or_writes_output(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(BENCH.main(self.argv() + ["--plan-only"]), 0)
        plan = json.loads(output.getvalue())
        self.assertEqual(plan["order"], ["established", "assembly"])
        self.assertFalse(self.output.exists())

    def test_destructive_run_requires_exact_confirmation(self):
        for extra in ([], ["--confirm-disposable-device", "wrong"]):
            with self.subTest(extra=extra), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    BENCH.main(self.argv() + extra)
        self.assertFalse(self.output.exists())

    def test_booted_alias_rejected(self):
        argv = self.argv()
        argv[1] = "booted"
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            BENCH.main(argv + ["--plan-only"])

    def test_invalid_deadlines_rejected_without_side_effects(self):
        for flag, value in (("--timeout", "nan"), ("--timeout", "0"),
                            ("--timeout", "inf"), ("--idle-seconds", "-1")):
            with self.subTest(flag=flag, value=value), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    BENCH.main(self.argv() + ["--plan-only", flag, value])
        self.assertFalse(self.output.exists())

    def test_completion_rejects_multirun_or_existing_file(self):
        completion = self.root / "completion.json"
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            BENCH.main(self.argv() + ["--plan-only", "--completion-file", str(completion)])
        completion.write_text("stale")
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            BENCH.main(self.argv()[:-1] + ["--plan-only", "--completion-file", str(completion)])

    def test_invalid_container_does_not_create_output(self):
        self.output = self.data / "output"
        with patch.object(BENCH, "command", side_effect=[str(self.data), str(self.app)]), \
                contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            BENCH.main(self.argv() + ["--confirm-disposable-device", DEVICE])
        self.assertFalse(self.output.exists())

    def test_preflight_identity_failure_does_not_terminate_or_restore(self):
        self.output.mkdir()
        (self.app / "Pinecone").write_bytes(b"changed binary")
        with patch.object(BENCH, "terminate_for_restore") as terminate:
            result = BENCH.run_attempt(self.args, self.manifest, 1, "assembly", self.data, self.app)
        terminate.assert_not_called()
        self.assertEqual(result["failureStage"], "preflight")
        self.assertFalse((self.disk_dir / "rootfs.ext4").exists())

    def test_restore_failure_retained(self):
        self.output.mkdir()
        with patch.object(BENCH, "terminate_for_restore"), \
                patch.object(BENCH, "command", side_effect=OSError("clone failed")):
            result = BENCH.run_attempt(self.args, self.manifest, 1, "assembly", self.data, self.app)
        self.assertEqual(result["failureStage"], "restore")
        self.assertIn("clone failed", result["failure"])
        self.assertFalse((self.disk_dir / "rootfs.ext4").exists())
        self.assertEqual(BENCH.digest(self.seed), self.manifest["seedSHA256"])

    def test_cohort_failure_preserves_failed_and_unattempted_rows(self):
        failure = {"attemptId": "01-established", "variant": "established", "status": "failed", "failure": "fixture failure"}
        with patch.object(BENCH, "command", side_effect=[str(self.data), str(self.app), "OS fixture", "CPU fixture", "{}"]), \
                patch.object(BENCH, "run_attempt", return_value=failure) as run, \
                contextlib.redirect_stdout(io.StringIO()):
            code = BENCH.main(self.argv() + ["--confirm-disposable-device", DEVICE])
        self.assertEqual(code, 1)
        run.assert_called_once()
        rows = json.loads((self.output / "summary.json").read_text())
        self.assertEqual(rows[0], failure)
        self.assertEqual(rows[1]["status"], "notAttempted")

    def test_existing_output_never_overwritten(self):
        self.output.mkdir()
        marker = self.output / "failure.json"
        marker.write_text("retained")
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            BENCH.main(self.argv() + ["--plan-only"])
        self.assertEqual(marker.read_text(), "retained")

    def test_unknown_termination_failure_aborts(self):
        with patch.object(BENCH.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 1, "", "Simulator unavailable")):
            with self.assertRaisesRegex(RuntimeError, "cannot confirm stopped"):
                BENCH.terminate_for_restore(DEVICE, self.root)
        self.assertEqual(BENCH.read_object(self.root / "terminate.json")["returncode"], 1)

    def test_known_not_running_termination_is_allowed(self):
        with patch.object(BENCH.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 1, "", "found nothing to terminate")):
            BENCH.terminate_for_restore(DEVICE, self.root)

    def test_success_retains_ready_raw_and_samples(self):
        result = self.run_fixture()
        self.assertIsNone(result["failure"])
        self.assertEqual(result["sampledPeakRSSMiB"], 2)
        self.assertEqual(result["combinedNativeStepsAtReady"], 30)
        self.assertTrue((self.output / "01-assembly/ready.json").exists())
        self.assertTrue((self.output / "01-assembly/pinecone-uart.log").exists())

    def test_launch_failure_retained_with_null_not_zero_memory(self):
        result = self.run_fixture(launch_error=subprocess.CalledProcessError(1, "launch", output="failed"))
        self.assertEqual(result["failureStage"], "launch")
        self.assertEqual(result["commandOutput"], "failed")
        self.assertIsNone(result["sampledPeakRSSMiB"])

    def test_flag_failure_retains_raw_report(self):
        result = self.run_fixture(report=report_for("established"))
        self.assertEqual(result["status"], "failed")
        self.assertTrue((self.output / "01-assembly/pinecone-performance.json").exists())

    def test_fallback_rejected_and_retained(self):
        report = report_for()
        report["executionAtMilestones"]["interactiveWorkloadReady"]["secondaryFallbackSteps"] = 1
        result = self.run_fixture(report=report)
        self.assertIn("Swift fallback", result["failure"])
        self.assertTrue((self.output / "01-assembly/ready.json").exists())

    def test_no_assembly_work_rejected(self):
        report = report_for()
        report["assemblyExecutorPrimary"]["steps"] = 0
        self.assertIn("no primary assembly", self.run_fixture(report=report)["failure"])

    def test_no_chain_work_rejected_and_retained(self):
        report = report_for("assembly-chain")
        report["assemblyExecutorPrimary"]["chainSteps"] = 0
        result = self.run_fixture(variant="assembly-chain", report=report)
        self.assertIn("no primary chain", result["failure"])
        self.assertTrue((self.output / "01-assembly-chain/ready.json").exists())

    def test_first_frame_only_times_out(self):
        result = self.run_fixture(report=report_for(ready=False))
        self.assertIn("readiness timeout", result["failure"])
        self.assertIsNone(result["observedReadySeconds"])

    def test_observer_timeout_is_not_guest_timeout(self):
        self.args.completion_file = self.root / "completion.json"
        result = self.run_fixture()
        self.assertIn("observer deadline expired (not guest timeout)", result["failure"])
        self.assertEqual(result["guestReadySeconds"], 2)

    def test_completion_cannot_replace_readiness(self):
        self.args.completion_file = self.root / "completion.json"
        self.args.completion_file.write_text("premature marker")
        result = self.run_fixture(report=report_for(ready=False))
        self.assertIn("readiness timeout", result["failure"])
        self.assertTrue((self.output / "01-assembly/completion.json").exists())

    def test_post_attempt_binary_drift_rejected(self):
        def mutate(_pid):
            (self.app / "Pinecone").write_bytes(b"unexpected update")
            return {"cpuSeconds": 1, "rssKiB": 2048, "psCPUPercent": 99}

        result = self.run_fixture(sample_error=mutate)
        self.assertEqual(result["status"], "failed")
        self.assertIn("appSHA256", result["identityError"])

    def test_ps_and_screenshot_failures_retained(self):
        result = self.run_fixture(sample_error=RuntimeError("process disappeared"))
        self.assertIn("process disappeared", result["failure"])
        self.assertTrue((self.output / "01-assembly/pinecone-performance.json").exists())

    def test_screenshot_failure_retains_readiness(self):
        result = self.run_fixture(screenshot_error=RuntimeError("screenshot failed"))
        self.assertIn("screenshot failed", result["failure"])
        self.assertEqual(result["guestReadySeconds"], 2)

    def test_interrupt_retained(self):
        result = self.run_fixture(sample_error=KeyboardInterrupt())
        self.assertIn("KeyboardInterrupt", result["failure"])

    def test_completion_requires_identity_semantic_evidence_and_latency(self):
        path = self.root / "completion.json"
        valid = {"attemptId": "01-assembly", "variant": "assembly", "attempts": [{
            "id": "tap-1", "workload": "unlock", "expected": "Home", "observed": "Home",
            "evidence": "video frame 123", "inputProtocol": "validated contact trace",
            "outcome": "success", "latencyMilliseconds": 100}]}
        BENCH.write_json(path, valid)
        self.assertEqual(BENCH.parse_completion(path, "01-assembly", "assembly"), valid)
        bad_cases = [{**valid, "attemptId": "other"}, {**valid, "attempts": []}]
        for field in ("evidence", "latencyMilliseconds", "inputProtocol"):
            bad = copy.deepcopy(valid)
            del bad["attempts"][0][field]
            bad_cases.append(bad)
        for bad in bad_cases:
            BENCH.write_json(path, bad)
            with self.assertRaises(ValueError):
                BENCH.parse_completion(path, "01-assembly", "assembly")

    def test_completion_preserves_timeout_kind(self):
        path = self.root / "completion.json"
        value = {"attemptId": "01-assembly", "variant": "assembly", "attempts": [{
            "id": "tap-1", "workload": "tap", "expected": "changed label", "observed": "no response",
            "evidence": "video", "inputProtocol": "validated trace", "outcome": "observer_timeout",
            "latencyMilliseconds": None}]}
        BENCH.write_json(path, value)
        self.assertEqual(BENCH.parse_completion(path, "01-assembly", "assembly")["attempts"][0]["outcome"],
                         "observer_timeout")

    def comparison_fixture(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            BENCH.main(self.argv() + ["--plan-only"])
        plan = json.loads(output.getvalue())
        path = self.root / "reference-identity.json"
        BENCH.write_json(path, plan)
        return path, plan

    def test_comparison_allows_changed_build_and_reversed_order(self):
        path, plan = self.comparison_fixture()
        plan["manifest"]["appSHA256"] = "f" * 64
        plan["manifest"]["sourceState"] = "candidate source identity"
        plan["order"].reverse()
        comparison = BENCH.comparison_record(path, plan)
        self.assertEqual(comparison["candidateAppSHA256"], "f" * 64)
        self.assertEqual(comparison["referenceAppSHA256"], self.manifest["appSHA256"])
        self.assertEqual(comparison["referenceIdentitySHA256"], BENCH.digest(path))

    def test_comparison_rejects_workload_identity_or_instrumentation_changes(self):
        path, plan = self.comparison_fixture()
        for key in ("seedSHA256", "fingerprintSHA256", "kernelSHA256", "compilerFlags",
                    "guestPackages", "cacheDiagnostics", "hostConditions", "inputProtocol"):
            with self.subTest(key=key):
                changed = copy.deepcopy(plan)
                changed["manifest"][key] = "different"
                with self.assertRaisesRegex(ValueError, key):
                    BENCH.comparison_record(path, changed)

    def test_comparison_rejects_runtime_or_harness_changes(self):
        path, plan = self.comparison_fixture()
        for key in ("device", "vcpus", "parallel", "timeoutSeconds", "idleSeconds",
                    "instrumentation", "settings", "harnessSHA256"):
            with self.subTest(key=key):
                changed = copy.deepcopy(plan)
                changed[key] = "different"
                with self.assertRaisesRegex(ValueError, key):
                    BENCH.comparison_record(path, changed)

    def test_comparison_rejects_missing_control_or_observer_mode_change(self):
        path, plan = self.comparison_fixture()
        changed = copy.deepcopy(plan)
        changed["order"] = ["assembly"]
        with self.assertRaisesRegex(ValueError, "attempt counts"):
            BENCH.comparison_record(path, changed)
        changed = copy.deepcopy(plan)
        changed["completionFile"] = "new-observer.json"
        with self.assertRaisesRegex(ValueError, "observer"):
            BENCH.comparison_record(path, changed)

    def test_compare_to_plan_is_local_only(self):
        path, _ = self.comparison_fixture()
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(BENCH.main(self.argv() + ["--plan-only", "--compare-to", str(path)]), 0)
        self.assertIn("comparison", json.loads(output.getvalue()))
        self.assertFalse(self.output.exists())

    def test_application_milestones_are_journaled_once_not_semantic_success(self):
        report = report_for()
        report["elapsedMilliseconds"]["applicationLaunchRequested"] = 3000
        report["elapsedMilliseconds"]["applicationFirstVisibleFrame"] = 3500
        seen = {}
        BENCH.record_milestones(self.root, report, 4, seen)
        BENCH.record_milestones(self.root, report, 5, seen)
        rows = [json.loads(line) for line in (self.root / "milestone-observations.jsonl").read_text().splitlines()]
        self.assertEqual(len(rows), 4)
        self.assertEqual(rows[-1]["milestone"], "applicationFirstVisibleFrame")
        self.assertEqual(rows[-1]["observerElapsedSeconds"], 4)
        self.assertNotIn("outcome", rows[-1])

    def test_changed_milestone_rejected(self):
        report = report_for()
        seen = {}
        BENCH.record_milestones(self.root, report, 3, seen)
        report["elapsedMilliseconds"]["interactiveWorkloadReady"] = 2001
        with self.assertRaisesRegex(ValueError, "changed"):
            BENCH.record_milestones(self.root, report, 4, seen)

    def test_post_ready_fallback_fails_and_retains_milestone(self):
        report = report_for()
        report["elapsedMilliseconds"]["applicationSurfacePresented"] = 3000
        counts = dict(report["executionAtMilestones"]["interactiveWorkloadReady"])
        counts["secondaryFallbackSteps"] = 1
        report["executionAtMilestones"]["applicationSurfacePresented"] = counts
        result = self.run_fixture(report=report)
        self.assertIn("applicationSurfacePresented", result["failure"])
        self.assertTrue((self.output / "01-assembly/milestone-observations.jsonl").exists())

    def test_malformed_post_ready_counters_rejected(self):
        report = report_for()
        report["executionAtMilestones"]["applicationSurfacePresented"] = {"primaryNativeSteps": 1}
        with self.assertRaisesRegex(ValueError, "applicationSurfacePresented"):
            BENCH.parse_report(report, "assembly")


if __name__ == "__main__":
    unittest.main()
