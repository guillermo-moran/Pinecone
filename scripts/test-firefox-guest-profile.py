#!/usr/bin/env python3
"""Offline shell-wrapper tests. Never starts Firefox or contacts a guest."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "scripts/profile-firefox-guest.sh"


class GuestProfileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="firefox-profile-test-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.bin = self.work / "bin"
        self.bin.mkdir()
        self.proc = self.work / "proc"
        (self.proc / "self").mkdir(parents=True)
        (self.proc / "self/status").write_text("Seccomp: 2\n")
        (self.proc / "uptime").write_text("123.45 67.89\n")
        self.home = self.work / "home"
        self.profile = self.home / ".mozilla/pinecone"
        self.profile.mkdir(parents=True)
        self.prefs = self.profile / "user.js"
        self.prefs.write_text('user_pref("existing.fixture", true);\n')
        self.original = self.prefs.read_bytes()
        # Relocate procfs in the test copy only; production exposes no bypass.
        self.script = self.work / "wrapper.sh"
        self.script.write_text(WRAPPER.read_text().replace("/proc/", f"{self.proc}/"))
        self.capture = self.work / "capture.json"
        self.out = self.work / "run with spaces"
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("MOZ_", "PINECONE_", "LD_"))}
        self.env.update(PATH=f"{self.bin}:{os.environ['PATH']}", HOME=str(self.home),
                        WAYLAND_DISPLAY="wayland-fixture", XDG_RUNTIME_DIR=str(self.work),
                        DBUS_SESSION_BUS_ADDRESS="unix:path=/fixture-bus",
                        TEST_CAPTURE=str(self.capture))
        self.program("firefox", '''
import os
assert os.environ.get("MOZ_PROFILER_HELP") == "1"
assert "MOZ_PROFILER_STARTUP" not in os.environ
if os.environ.get("TEST_HELP_FAIL"):
    raise SystemExit(7)
if not os.environ.get("TEST_NO_PROFILER"):
    for option in ("STARTUP", "STARTUP_ENTRIES", "STARTUP_INTERVAL",
                   "STARTUP_FEATURES", "STARTUP_FILTERS", "SHUTDOWN"):
        if option != os.environ.get("TEST_MISSING_OPTION"):
            print("  MOZ_PROFILER_" + option)
    for name in ("js", "stackwalk", "cpu"):
        flag = "x" if name == os.environ.get("TEST_UNAVAILABLE") else "D"
        print(f'    {flag}       1: "{name}" (fixture)')
''')
        self.program("pinecone-launch-firefox", '''
import json, os, pathlib, sys
pathlib.Path(os.environ["TEST_CAPTURE"]).write_text(json.dumps({
    "args": sys.argv[1:], "env": dict(os.environ)}))
if not os.environ.get("TEST_NO_OUTPUT"):
    pathlib.Path(os.environ["MOZ_PROFILER_SHUTDOWN"]).write_text('{"meta": {}, "threads": []}')
raise SystemExit(int(os.environ.get("TEST_LAUNCH_STATUS", "0")))
''')

    def program(self, name, source):
        path = self.bin / name
        path.write_text(f"#!/bin/sh\nexec {shlex.quote(sys.executable)} - \"$@\" <<'PY'\n{source}\nPY\n")
        path.chmod(0o755)

    def run_wrapper(self, *args, **env):
        return subprocess.run(["sh", str(self.script), *map(str, args)],
                              env={**self.env, **env}, text=True,
                              capture_output=True, timeout=10)

    def capture_run(self, *urls, **env):
        return self.run_wrapper("--capture", self.out, *urls, **env)

    def assert_not_launched(self, result):
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.capture.exists())
        self.assertEqual(self.prefs.read_bytes(), self.original)

    def test_help_has_no_side_effects(self):
        self.assertEqual(self.run_wrapper("--help").returncode, 0)
        self.assertFalse(self.out.exists())
        self.assertFalse(self.capture.exists())

    def test_explicit_opt_in_required(self):
        self.assert_not_launched(self.run_wrapper())
        self.assert_not_launched(self.run_wrapper(self.out))

    def test_default_delegates_without_url_or_browser_flags(self):
        result = self.capture_run()
        self.assertEqual(result.returncode, 0, result.stderr)
        captured = json.loads(self.capture.read_text())
        self.assertEqual(captured["args"], [])
        env = captured["env"]
        self.assertEqual(env["MOZ_PROFILER_STARTUP_ENTRIES"], "1048576")
        self.assertEqual(env["MOZ_PROFILER_STARTUP_INTERVAL"], "10")
        self.assertEqual(env["MOZ_PROFILER_STARTUP_FILTERS"], "GeckoMain")
        self.assertEqual(env["MOZ_PROFILER_STARTUP_FEATURES"], "js,stackwalk,cpu")
        self.assertEqual(env["DBUS_SESSION_BUS_ADDRESS"], self.env["DBUS_SESSION_BUS_ADDRESS"])
        self.assertEqual(env["HOME"], str(self.home))
        self.assertNotIn("MOZ_PROFILER_STARTUP_DURATION", env)
        self.assertNotIn("MOZ_PROFILER_HELP", env)
        self.assertEqual(self.prefs.read_bytes(), self.original)
        self.assertEqual(self.out.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.out / "run.txt").stat().st_mode & 0o777, 0o600)
        self.assertIn("exit_status=0", (self.out / "run.txt").read_text())

    def test_urls_are_preserved_without_shell_interpretation(self):
        urls = ["about:blank", "https://example.com/?q=two words&x=$(false)", "file:///tmp/a b.html"]
        result = self.capture_run(*urls)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.capture.read_text())["args"], urls)

    def test_preserves_graphics_session_environment(self):
        result = self.capture_run(LD_PRELOAD="/fixture/libpinecone-pixman.so",
                                  GSK_RENDERER="cairo", PINECONE_PIXMAN_OPERATOR_MASK="0x3fff")
        self.assertEqual(result.returncode, 0, result.stderr)
        env = json.loads(self.capture.read_text())["env"]
        self.assertEqual(env["LD_PRELOAD"], "/fixture/libpinecone-pixman.so")
        self.assertEqual(env["GSK_RENDERER"], "cairo")
        self.assertEqual(env["PINECONE_PIXMAN_OPERATOR_MASK"], "0x3fff")

    def test_options_and_unsupported_urls_rejected(self):
        for url in ("--no-remote", "-profile", "javascript:alert(1)", "data:text/html,x", ""):
            with self.subTest(url=url):
                self.assert_not_launched(self.capture_run(url))
        self.assertFalse(self.out.exists())

    def test_bounded_knobs_and_graphics_mode(self):
        result = self.capture_run("about:blank", PINECONE_FIREFOX_PROFILE_MODE="graphics",
                                  PINECONE_FIREFOX_PROFILE_INTERVAL_MS="50",
                                  PINECONE_FIREFOX_PROFILE_ENTRIES="4194304")
        self.assertEqual(result.returncode, 0, result.stderr)
        env = json.loads(self.capture.read_text())["env"]
        self.assertIn("SwComposite", env["MOZ_PROFILER_STARTUP_FILTERS"])
        self.assertIn("Software", env["MOZ_PROFILER_STARTUP_FILTERS"])
        self.assertEqual(env["MOZ_PROFILER_STARTUP_INTERVAL"], "50")
        self.assertEqual(env["MOZ_PROFILER_STARTUP_ENTRIES"], "4194304")

    def test_invalid_knobs(self):
        for key, values in {
            "MODE": ["all", "main;false"],
            "INTERVAL_MS": ["0", "1", "-1", "NaN", "100000", "10;false"],
            "ENTRIES": ["0", "-1", "999999999999999", "1MiB"],
        }.items():
            for value in values:
                with self.subTest(key=key, value=value):
                    self.assert_not_launched(self.capture_run(**{f"PINECONE_FIREFOX_PROFILE_{key}": value}))

    def test_inherited_profiler_or_logging_settings_rejected(self):
        for key in ("MOZ_PROFILER_STARTUP_FEATURES_BITFIELD", "MOZ_PROFILER_STARTUP_DURATION",
                    "MOZ_PROFILER_HELP", "MOZ_BASE_PROFILER_STARTUP", "MOZ_LOG", "MOZ_LOG_FILE"):
            with self.subTest(key=key):
                self.assert_not_launched(self.capture_run(**{key: "1"}))

    def test_sandbox_and_isolation_overrides_rejected(self):
        for key in ("MOZ_DISABLE_CONTENT_SANDBOX", "MOZ_DISABLE_RDD_SANDBOX",
                    "MOZ_FORCE_DISABLE_E10S", "MOZ_FORCE_DISABLE_FISSION"):
            with self.subTest(key=key):
                self.assert_not_launched(self.capture_run(**{key: "1"}))

    def test_existing_output_not_overwritten(self):
        self.out.mkdir()
        sentinel = self.out / "shutdown.json"
        sentinel.write_text("preserve")
        self.assert_not_launched(self.capture_run())
        self.assertEqual(sentinel.read_text(), "preserve")

    def test_symlink_output_not_followed(self):
        self.out.symlink_to(self.profile, target_is_directory=True)
        self.assert_not_launched(self.capture_run())
        self.assertFalse((self.profile / "run.txt").exists())

    def test_percent_in_resolved_parent_refused(self):
        parent = self.work / "parent%p"
        parent.mkdir()
        alias = self.work / "alias"
        alias.symlink_to(parent, target_is_directory=True)
        self.assert_not_launched(self.run_wrapper("--capture", alias / "new-run"))

    def test_relative_and_percent_paths_rejected(self):
        for path in ("relative", str(self.out) + "%p"):
            self.assert_not_launched(self.run_wrapper("--capture", path))

    def test_running_firefox_refused(self):
        (self.proc / "42").mkdir()
        for name in ("firefox", "firefox-bin"):
            (self.proc / "42/comm").write_text(name + "\n")
            self.assert_not_launched(self.capture_run())
        self.assertFalse(self.out.exists())

    def test_missing_session_refused(self):
        for key in ("WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"):
            self.assert_not_launched(self.capture_run(**{key: "", "WAYLAND_SOCKET": ""}))

    def test_missing_seed_not_created(self):
        self.prefs.unlink()
        result = self.capture_run()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.prefs.exists())
        self.assertFalse(self.capture.exists())

    def test_no_host_execution(self):
        (self.proc / "self/status").unlink()
        self.assert_not_launched(self.capture_run())

    def test_help_failure_refuses_launch(self):
        self.assert_not_launched(self.capture_run(TEST_HELP_FAIL="1"))

    def test_build_without_profiler_refuses_launch(self):
        self.assert_not_launched(self.capture_run(TEST_NO_PROFILER="1"))

    def test_unavailable_stackwalk_refuses_launch(self):
        self.assert_not_launched(self.capture_run(TEST_UNAVAILABLE="stackwalk"))

    def test_missing_shutdown_option_refuses_launch(self):
        self.assert_not_launched(self.capture_run(TEST_MISSING_OPTION="SHUTDOWN"))

    def test_launcher_error_propagated(self):
        result = self.capture_run(TEST_LAUNCH_STATUS="19")
        self.assertEqual(result.returncode, 19)
        self.assertIn("exit_status=19", (self.out / "run.txt").read_text())

    def test_missing_capture_is_not_success(self):
        result = self.capture_run(TEST_NO_OUTPUT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no shutdown profile", result.stderr)


if __name__ == "__main__":
    unittest.main()
