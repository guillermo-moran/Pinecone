#!/usr/bin/env python3
"""Profiler shell compatibility with fake xcrun and dedicated temporary captures."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("profile-pinecone-phosh.sh")


@unittest.skipUnless(shutil.which("jq"), "jq is required by the existing profiler")
class ProfileCompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pinecone-owner6-profile-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.calls = self.root / "calls.jsonl"
        self.container = self.root / "container"
        (self.container / "Library/Caches").mkdir(parents=True)
        self.metrics = {
            "elapsedMilliseconds": {"interactiveWorkloadReady": 30,
                "applicationLaunchRequested": 40, "applicationSurfacePresented": 50},
            "executionAtMilestones": {"interactiveWorkloadReady": {
                "primaryNativeSteps": 100, "primaryFallbackSteps": 0, "secondaryFallbackSteps": 0}},
            "framePipeline": {"frameSampleCount": 1}, "interactions": [], "touchSampleCount": 0,
            "inputFrameCorrelation": "unavailable: no shared input/frame identity"}
        mock = self.bin / "xcrun"
        mock.write_text(f"#!{sys.executable}\n" + '''
import json
import os
from pathlib import Path
import sys
with open(os.environ["TEST_CALLS"], "a") as output:
    output.write(json.dumps({"args": sys.argv[1:], "env": {
        key: value for key, value in os.environ.items() if key.startswith("SIMCTL_CHILD_")}}) + "\\n")
command = sys.argv[1:3]
if command == ["simctl", "get_app_container"]:
    print(os.environ["TEST_CONTAINER"])
elif command == ["simctl", "launch"]:
    cache = Path(os.environ["TEST_CONTAINER"]) / "Library/Caches"
    (cache / "pinecone-performance.json").write_bytes(Path(os.environ["TEST_METRICS"]).read_bytes())
    (cache / "pinecone-performance.log").write_text(os.environ.get("TEST_RUNTIME", "steps=100 stop=yielded\\n"))
elif command != ["simctl", "terminate"]:
    raise SystemExit("Unexpected fake-xcrun request: " + repr(sys.argv))
''')
        mock.chmod(0o755)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("PINECONE_", "SIMCTL_CHILD_"))}
        self.env.update(PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
            TEST_CALLS=str(self.calls), TEST_CONTAINER=str(self.container),
            TEST_METRICS=str(self.root / "metrics.json"), PINECONE_PROFILE_TIMEOUT_SECONDS="1")

    def run_profile(self, **env):
        (self.root / "metrics.json").write_text(json.dumps(self.metrics))
        return subprocess.run(["bash", str(SCRIPT)], env={**self.env, **env},
                              text=True, capture_output=True, timeout=5)

    def launch_environment(self):
        return next(json.loads(line)["env"] for line in self.calls.read_text().splitlines()
                    if json.loads(line)["args"][1] == "launch")

    def test_auto_unlock_zero_retired_touch_samples_exits_with_semantic_warning(self):
        result = self.run_profile(PINECONE_PROFILE_AUTO_UNLOCK="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["touchSampleCount"], 0)
        self.assertIn("does not wait for injection completion or prove unlock", result.stderr)
        self.assertIn("semantic UI observation is required", result.stderr)
        self.assertEqual(self.launch_environment()["SIMCTL_CHILD_PINECONE_INTERACTION_TRACE"], "1")

    def test_trace_off_forwarded_to_host_and_guest_without_policy_changes(self):
        result = self.run_profile(PINECONE_PROFILE_INTERACTION_TRACE="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        env = self.launch_environment()
        self.assertEqual(env["SIMCTL_CHILD_PINECONE_INTERACTION_TRACE"], "0")
        self.assertIn("PINECONE_INTERACTION_TRACE=0", env["SIMCTL_CHILD_PINECONE_SIMULATOR_AUTORUN_COMMAND"])
        self.assertEqual(env["SIMCTL_CHILD_PINECONE_VCPU_COUNT"], "2")
        self.assertEqual(env["SIMCTL_CHILD_PINECONE_EXPERIMENTAL_PARALLEL_VCPU"], "1")

    def test_positive_minimum_fails_before_any_device_command(self):
        for value in ("1", "001", "99999999999999999999999999999999999"):
            with self.subTest(value=value):
                result = self.run_profile(PINECONE_PROFILE_MIN_INTERACTIONS=value)
                self.assertEqual(result.returncode, 2)
                self.assertIn("causal interaction identity is unavailable", result.stderr)
                self.assertFalse(self.calls.exists())

    def test_invalid_minimum_and_trace_still_fail_before_any_device_command(self):
        for env in ({"PINECONE_PROFILE_MIN_INTERACTIONS": "-1"},
                    {"PINECONE_PROFILE_MIN_INTERACTIONS": "x"},
                    {"PINECONE_PROFILE_INTERACTION_TRACE": "2"}):
            with self.subTest(env=env):
                self.assertEqual(self.run_profile(**env).returncode, 2)
                self.assertFalse(self.calls.exists())

    def test_cli_application_still_requires_presentation_milestone(self):
        self.metrics["elapsedMilliseconds"].pop("applicationSurfacePresented")
        result = self.run_profile(PINECONE_PROFILE_APPLICATION_COMMAND="pinecone-launch-settings")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("presentation milestone missing", result.stderr)
        self.assertNotIn("completed interactions", result.stderr)

    def test_cli_application_milestone_and_latency_limit_remain_compatible(self):
        result = self.run_profile(PINECONE_PROFILE_APPLICATION_COMMAND="pinecone-launch-settings")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("semantic UI observation is required", result.stderr)
        result = self.run_profile(PINECONE_PROFILE_APPLICATION_COMMAND="pinecone-launch-settings",
                                  PINECONE_MAX_APPLICATION_LATENCY_MS="5")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Application launch regression", result.stderr)

    def test_fallback_and_runner_failure_still_fail(self):
        self.metrics["executionAtMilestones"]["interactiveWorkloadReady"]["secondaryFallbackSteps"] = 1
        result = self.run_profile()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Native-only regression", result.stderr)
        result = self.run_profile(TEST_RUNTIME="runner-failure=synthetic test failure\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("runner-failure=", result.stderr)

    def test_zero_minimum_and_native_step_guard_remain_compatible(self):
        self.assertEqual(self.run_profile(PINECONE_PROFILE_MIN_INTERACTIONS="000").returncode, 0)
        result = self.run_profile(PINECONE_MAX_READY_PRIMARY_STEPS="50")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Phosh readiness regression", result.stderr)


if __name__ == "__main__":
    unittest.main()
