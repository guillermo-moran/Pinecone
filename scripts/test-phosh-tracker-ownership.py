#!/usr/bin/env python3
"""Compile actual full-stack tracker callbacks with mocked service transports.

Run in the existing Linux builder. --source must include Alpine's
splash-timeout-flatpak-dbus.patch and the current Pinecone lifecycle stack.
No Phosh build, display, session bus, launch, or image mutation is performed.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import resource
import shlex
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent


def fixture_source(source):
    for marker in ("check_flatpak_state", "pinecone_launch_begin", "gint32 pid = 0"):
        if marker not in source:
            raise ValueError(f"Not the full Alpine/Pinecone stack: missing {marker}")
    body = source[source.index("/* Startup timeout"):]
    start = body.index("static void\nphosh_app_tracker_init (")
    end = body.index("\n\nPhoshAppTracker *\nphosh_app_tracker_new", start)
    body = body[:start] + '''static void
phosh_app_tracker_init (PhoshAppTracker *self)
{
  self->cancel = g_cancellable_new ();
  self->session_bus = g_object_new (G_TYPE_DBUS_CONNECTION, NULL);
  self->apps = g_hash_table_new_full (g_str_hash, g_str_equal, g_free,
                                     (GDestroyNotify) phosh_app_state_free);
  self->wl_tracker = (void *) 1;
  (void) startup_tracker_listener;
}
''' + body[end:]
    start = body.index("\nvoid\nphosh_app_tracker_launch_app_info (")
    launch = body[start:]
    # Keep the exact production connections, not a handwritten approximation.
    match = re.search(r"  g_signal_connect_(?:object|swapped) ", launch)
    connections = launch[match.start():launch.index("  exec =")]
    assert connections.count("G_CALLBACK (") == 3
    assert "g_object_ref (context)" not in launch
    assert "g_object_unref (context)" not in body
    return body[:start] + "\nstatic void\nbind_context (PhoshAppTracker *self, GAppLaunchContext *context)\n{\n" + connections + "}\n"


def splash_fixture_source(source):
    body = source[source.index("enum {"):]
    start = body.index('  self->interface_settings = g_settings_new (')
    end = body.index('\n}', start)
    # Keep real callbacks, signal wiring, dispose and finalize; omit only settings.
    return body[:start] + '  (void) gsettings_color_scheme_changed_cb;' + body[end:]


def run(source_dir, prove_baseline, sanitizer):
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    baseline = (source_dir / "src/app-tracker.c").read_text()
    splash_baseline = (source_dir / "src/splash-manager.c").read_text()
    print("Full-stack app-tracker.c SHA256:", hashlib.sha256(baseline.encode()).hexdigest(), flush=True)
    with tempfile.TemporaryDirectory(prefix="phosh-tracker-ownership-") as temporary:
        work = Path(temporary)
        (work / "src").mkdir()
        (work / "src/app-tracker.c").write_text(baseline)
        (work / "src/splash-manager.c").write_text(splash_baseline)
        (work / "app-tracker.h").write_text((source_dir / "src/app-tracker.h").read_text())
        patch = ROOT / "patches/phosh-pinecone-tracker-ownership.patch"
        subprocess.run(["patch", "--batch", "--fuzz=0", "-p1", "-d", str(work),
                        "-i", str(patch)], check=True)
        candidate = (work / "src/app-tracker.c").read_text()
        splash_candidate = (work / "src/splash-manager.c").read_text()
        desktop_dir = work / "applications"
        desktop_dir.mkdir()
        desktop = desktop_dir / "org.pinecone.TrackerFixture.desktop"
        desktop.write_text("[Desktop Entry]\nType=Application\nName=Tracker Fixture\n"
                           "Exec=/bin/true\nStartupNotify=true\n")
        env = {**os.environ, "TRACKER_DESKTOP": str(desktop), "XDG_DATA_HOME": str(work),
               "XDG_DATA_DIRS": str(work), "G_DEBUG": "fatal-criticals",
               "ASAN_OPTIONS": "detect_leaks=0:halt_on_error=1"}
        flags = shlex.split(subprocess.check_output(
            ["pkg-config", "--cflags", "--libs", "gio-unix-2.0"], text=True))
        cc = shlex.split(os.environ.get("CC", "cc"))
        cases = (("baseline", baseline, splash_baseline),
                 ("baseline-no-checks", baseline, splash_baseline),
                 ("candidate", candidate, splash_candidate),
                 ("candidate-no-checks", candidate, splash_candidate))
        for name, content, splash in cases:
            if name.startswith("baseline") and not prove_baseline:
                continue
            (work / "tracker.inc").write_text(fixture_source(content))
            (work / "splash.inc").write_text(splash_fixture_source(splash))
            checks = ["-DG_DISABLE_CHECKS"] if name.endswith("no-checks") else []
            binary = work / name
            subprocess.run([*cc, "-std=gnu11", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
                            "-Wno-unused-parameter", *sanitizer, *checks,
                            "-fno-omit-frame-pointer", "-I", str(work),
                            str(ROOT / "phosh-tracker-ownership-regression.c"),
                            *flags, "-o", str(binary)], check=True)
            if name.startswith("candidate"):
                subprocess.run([str(binary)], env=env, check=True)
            elif name == "baseline":
                for test in ("/tracker/timeout-remove", "/tracker/context-late",
                             "/tracker/flatpak-unit-retired",
                             "/tracker/flatpak-proxy-retired", "/tracker/bus-success"):
                    result = subprocess.run([str(binary), "-p", test], env=env,
                                            capture_output=True, text=True)
                    if result.returncode == 0:
                        raise AssertionError(f"Baseline unexpectedly passed {test}")
                    diagnostic = next((line.strip() for line in (result.stderr + result.stdout).splitlines()
                                       if "ERROR:" in line or "CRITICAL" in line or "assertion failed" in line),
                                      "no expected diagnostic")
                    if diagnostic == "no expected diagnostic" and result.returncode in (-4, -6, -11):
                        diagnostic = f"terminated by signal {-result.returncode}"
                    if diagnostic == "no expected diagnostic":
                        raise AssertionError(result.stderr + result.stdout)
                    print(f"Expected baseline failure {test}: {diagnostic}", flush=True)
            splash_binary = work / (name + "-splash")
            # Stock code uses key only inside g_return_if_fail, erased in this build.
            baseline_warning = (["-Wno-error=unused-but-set-variable"]
                                if name == "baseline-no-checks" else [])
            subprocess.run([*cc, "-std=gnu11", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
                            "-Wno-unused-parameter", *sanitizer, *checks, *baseline_warning,
                            "-fno-omit-frame-pointer", "-I", str(work),
                            str(ROOT / "phosh-splash-ownership-regression.c"),
                            *flags, "-o", str(splash_binary)], check=True)
            if name.startswith("candidate"):
                subprocess.run([str(splash_binary)], env=env, check=True)
            else:
                tests = (("/splash/close-removes",) if checks else
                         ("/splash/finalized", "/splash/disposed", "/splash/close-retired"))
                for test in tests:
                    result = subprocess.run([str(splash_binary), "-p", test], env=env,
                                            capture_output=True, text=True)
                    if result.returncode == 0 or "ERROR:" not in result.stdout + result.stderr:
                        raise AssertionError(f"Expected baseline assertion: {test}\n{result.stdout}{result.stderr}")
                    print(f"Expected {name} assertion: {test}", flush=True)
    print("PASS: full-stack callback ownership regressions", " ".join(sanitizer))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--prove-baseline", action="store_true")
    parser.add_argument("--asan", action="store_true", help="Requires installed ASan/UBSan runtimes")
    args = parser.parse_args()
    sanitizer = (["-fsanitize=address,undefined"] if args.asan else
                 ["-fsanitize=undefined", "-fsanitize-undefined-trap-on-error"])
    run(args.source, args.prove_baseline, sanitizer)
