"""Host-side tests for diagnostic command generation; not a guest policy test."""
import importlib.util
from pathlib import Path
import shlex
import subprocess
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "prepare-lineageos-focused-native-stacks.py"
SPEC = importlib.util.spec_from_file_location("focused_stacks", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class FocusedNativeStacksTests(unittest.TestCase):
    def test_default_targets_unchanged(self):
        self.assertEqual(MODULE.selected_targets(None), list(MODULE.KNOWN_TARGETS))

    def test_explicit_targets_prioritized_and_deduplicated(self):
        self.assertEqual(
            MODULE.selected_targets([
                "com.android.systemui", "surfaceflinger", "system_server",
                "surfaceflinger",
            ]),
            ["system_server", "surfaceflinger", "com.android.systemui"],
        )

    def test_argument_preserves_shell_quotes_backslashes_and_dollars(self):
        command = MODULE.capture_command(["system_server"], 10, 5, 2, 20)
        # POSIX tokenization checks the common double-quote/backslash subset
        # used here. Actual init expansion and SELinux still require a boot.
        self.assertEqual(shlex.split(MODULE.init_argument(command)), [command])
        self.assertIn('"$$p"', command)
        self.assertIn("tr '\\000' '\\n'", command)
        self.assertIn("p=$${p%% *}", command)

    def test_generated_shell_syntax_and_absent_process_flow(self):
        command = MODULE.capture_command(
            ["system_server", "surfaceflinger"], 10, 5, 2, 20
        ).replace("$$", "$")
        subprocess.run(["/bin/sh", "-n"], input=command, text=True, check=True)
        # No real sleeping, guest process access, or debugger invocation.
        stubs = "sleep() { :; }; pidof() { :; }; log() { cat; };\n"
        result = subprocess.run(
            ["/bin/sh"], input=stubs + command, text=True,
            capture_output=True, check=True, timeout=5,
        )
        self.assertEqual(result.stdout.splitlines()[0], "SERVICE_STARTED")
        self.assertEqual(result.stdout.count("SERVICE_STARTED"), 1)
        for sample in (1, 2):
            for target in ("system_server", "surfaceflinger"):
                marker = f"SAMPLE_{sample}_PROCESS_{target}"
                self.assertIn(f"BEGIN_{marker}", result.stdout)
                self.assertIn(f"END_{marker}", result.stdout)
        self.assertEqual(result.stdout.count("PROCESS_ABSENT_system_server"), 2)
        self.assertEqual(result.stdout.count("PROCESS_ABSENT_surfaceflinger"), 2)

    def test_service_started_marker_precedes_initial_delay(self):
        command = MODULE.capture_command(["system_server"], 150, 15, 1, 20)
        self.assertLess(command.index("echo SERVICE_STARTED"), command.index("sleep 150"))
        self.assertLess(command.index("echo SERVICE_STARTED"), command.index("BEGIN_SAMPLE_1"))

    def test_invalid_bounds_fail_before_reading_source(self):
        for option, value in (
            ("--samples", "0"), ("--samples", "4"),
            ("--delay-seconds", "-1"),
            ("--sample-interval-seconds", "3601"),
            ("--per-process-timeout", "0"),
            ("--target", "untrusted-process"),
        ):
            with self.subTest(option=option, value=value):
                result = subprocess.run(
                    ["python3", str(SCRIPT), "missing-source", "unused-output", option, value],
                    capture_output=True, text=True, timeout=5,
                )
                self.assertEqual(result.returncode, 2)
                self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
