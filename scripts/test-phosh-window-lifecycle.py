#!/usr/bin/env python3
"""Execute extracted Phosh window-lifecycle functions with real GLib/GObject.

python3 scripts/test-phosh-window-lifecycle.py --source /tmp/phosh-0.57.0 \
    --check-baseline

Only temporary copies are patched. Requires cc, patch, pkg-config and gio-2.0
development files; no GTK/display, guest image, or full Phosh build is needed.
Use --already-patched to test an existing patched source tree without modifying it.
Both normal and G_DISABLE_CHECKS builds execute by default. --sanitizers undefined
selects UBSan alone; --sanitizers without a value enables ASan and UBSan.
Exit status 2 denotes incomplete timeout evidence, not a functional failure.
"""

import argparse
import hashlib
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile


FUNCTIONS = {
    "toplevel-manager.c": [
        "on_initial_toplevel_timeout", "launching_app_info_free",
        "launching_app_info_new", "app_info_has_toplevel", "remove_from_launching",
        "on_app_launched", "on_toplevel_configured",
    ],
    "overview.c": [
        "find_activity_by_app_info", "phosh_overview_get_toplevel_from_activity",
        "find_activity_by_toplevel", "on_toplevel_missing", "on_app_failed",
        "on_toplevel_closed",
    ],
}
BASELINE_FAILURES = [
    "/manager/valid-id-cancels-timeout",
    "/manager/null-id-ignored",
    "/manager/desktop-alias-already-mapped",
    "/manager/duplicate-launches-cancelled",
    "/manager/late-app-id-configure",
    "/overview/mapped-without-thumbnail",
    "/overview/unmapped-selected-cleared",
    "/overview/stale-failure-keeps-newer-splash",
    "/overview/close-clears-selection-before-destroy",
    "/manager/timeout-reentrancy",
]


def extract_function(source, name):
    """Keep function bytes verbatim; brace scanning ignores C comments/literals."""
    pattern = re.compile(
        r"(?m)^(?:static\s+)?[A-Za-z_][\w \t*]*\n" + re.escape(name)
        + r"\s*\([^;{}]*\)\s*\{"
    )
    matches = list(pattern.finditer(source))
    if len(matches) != 1:
        raise ValueError(f"Expected one definition of {name}, found {len(matches)}")
    match = matches[0]
    start = match.end() - 1
    depth = 0
    i = start
    while i < len(source):
        if source.startswith("/*", i):
            end = source.find("*/", i + 2)
            if end < 0:
                break
            i = end + 2
            continue
        if source.startswith("//", i):
            end = source.find("\n", i + 2)
            i = len(source) if end < 0 else end + 1
            continue
        char = source[i]
        if char in "\"'":
            quote = char
            i += 1
            while i < len(source):
                if source[i] == "\\":
                    i += 2
                elif source[i] == quote:
                    i += 1
                    break
                else:
                    i += 1
            continue
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[match.start():i + 1]
        i += 1
    raise ValueError(f"Unterminated function {name}")


def expected_baseline_failure(case, output):
    assertion = re.search(r"ERROR:[^\n]*phosh-window-lifecycle-regression\.c:\d+:", output)
    # The old mapped-window path warns before destroying the live activity.
    wrong_splash_warning = (
        case == "/overview/mapped-without-thumbnail" and
        "FATAL-WARNING" in output and
        "App org.gnome.TextEditor.desktop didn't present a toplevel, hiding splash" in output
    )
    return bool(assertion or wrong_splash_warning)


def timeout_output(error):
    # TimeoutExpired can retain bytes even when subprocess text mode is enabled.
    return "".join(part.decode(errors="replace") if isinstance(part, bytes) else part or ""
                   for part in [error.stdout, error.stderr])


def build(source_dir, work, sanitizers, disable_checks=False):
    fragments = []
    for filename, names in FUNCTIONS.items():
        source = (source_dir / "src" / filename).read_text()
        for name in names:
            function = extract_function(source, name)
            digest = hashlib.sha256(function.encode()).hexdigest()
            print(f"extract {filename}:{name} sha256={digest}", flush=True)
            fragments.append(function)
    overview = (source_dir / "src/overview.c").read_text()
    hookup = re.search(r'g_signal_connect_object\s*\(activity,\s*"destroy",\s*'
                       r'G_CALLBACK\s*\(on_activity_destroyed\),\s*self,\s*G_CONNECT_SWAPPED\);',
                       extract_function(overview, "create_new_activity"))
    if hookup:
        handler = extract_function(overview, "on_activity_destroyed")
        print("extract overview.c:on_activity_destroyed sha256=" +
              hashlib.sha256(handler.encode()).hexdigest(), flush=True)
        fragments.append(handler)
    elif "on_activity_destroyed" in overview:
        raise ValueError("Activity destroy handler exists without expected production hookup")
    fragments.append("static void fixture_connect_activity (PhoshOverview *self, PhoshActivity *activity)\n"
                     "{\n" + (hookup.group() if hookup else "") + "\n}")
    (work / "extracted-lifecycle.h").write_text("\n\n".join(fragments) + "\n")
    flags = shlex.split(subprocess.check_output(
        ["pkg-config", "--cflags", "--libs", "gio-2.0", "gobject-2.0"], text=True))
    sdk = []
    if sys.platform == "darwin":
        sdk = ["-isysroot", subprocess.check_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()]
    sanitizer_flags = [f"-fsanitize={sanitizers}", "-fno-sanitize-recover=all",
                       "-fno-omit-frame-pointer"] if sanitizers else []
    check_flags = ["-DG_DISABLE_CHECKS"] if disable_checks else []
    executable = work / ("window-lifecycle-no-checks-test" if disable_checks else "window-lifecycle-test")
    subprocess.run(shlex.split(os.environ.get("CC", "cc")) + [
        "-std=c11", "-g", "-Wall", "-Wextra", "-Werror",
        "-Wno-unused-parameter", "-Wno-sign-compare", *sdk, *sanitizer_flags, *check_flags,
        "-I", str(work), str(Path(__file__).with_name("phosh-window-lifecycle-regression.c")),
        *flags, "-o", str(executable),
    ], check=True, timeout=60)
    return executable


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path("/tmp/phosh-0.57.0"))
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--patch", type=Path)
    mode.add_argument("--already-patched", action="store_true")
    parser.add_argument("--check-baseline", action="store_true",
                        help="require the original source to fail each known-bug case")
    parser.add_argument("--sanitizers", nargs="?", const="address,undefined",
                        choices=["address,undefined", "undefined"], metavar="SET")
    args = parser.parse_args()
    if args.already_patched and args.check_baseline:
        parser.error("--check-baseline requires unpatched --source")
    patch = args.patch or Path(__file__).parent / "patches/phosh-pinecone-window-lifecycle.patch"
    if not args.already_patched and not patch.is_file():
        parser.error(f"Lifecycle patch is not available: {patch}")
    env = {**os.environ, "G_DEBUG": "fatal-warnings"}
    baseline_incomplete = False
    with tempfile.TemporaryDirectory(prefix="phosh-window-lifecycle-") as directory:
        work = Path(directory)
        source_dir = work / "source"
        (source_dir / "src").mkdir(parents=True)
        for filename in FUNCTIONS:
            shutil.copyfile(args.source / "src" / filename, source_dir / "src" / filename)
        if args.check_baseline:
            executable = build(source_dir, work, args.sanitizers)
            for case in BASELINE_FAILURES:
                try:
                    result = subprocess.run([str(executable), "-p", case], cwd=work,
                                            env=env, capture_output=True, text=True, timeout=10)
                except subprocess.TimeoutExpired as error:
                    output = timeout_output(error)
                    evidence = "expected assertion/warning observed" if expected_baseline_failure(case, output) \
                        else "no expected assertion/warning captured"
                    print(f"INCOMPLETE baseline: {case} timed out; {evidence}.\n"
                          "Process completion is unverified, not a logic-failure verdict.\n" + output,
                          flush=True)
                    print("Skipping remaining baseline abort cases; running fixed builds separately.", flush=True)
                    baseline_incomplete = True
                    break
                output = result.stdout + result.stderr
                if result.returncode == 0 or not expected_baseline_failure(case, output):
                    raise RuntimeError(f"Baseline did not produce its expected failure: {case}\n"
                                       f"{result.stdout}{result.stderr}")
                print(f"PASS negative control: {case} rejected original source", flush=True)
        if not args.already_patched:
            subprocess.run(["patch", "--batch", "--forward", "--fuzz=0", "-p1",
                            "-i", str(patch.resolve())], cwd=source_dir, check=True, timeout=10)
        for disable_checks in [False, True]:
            print("BUILD: " + ("G_DISABLE_CHECKS" if disable_checks else "normal"), flush=True)
            executable = build(source_dir, work, args.sanitizers, disable_checks)
            try:
                subprocess.run([str(executable)], cwd=work, env=env, check=True, timeout=20)
            except subprocess.TimeoutExpired:
                print("INCOMPLETE fixed build: execution timed out; no logic-failure verdict.", flush=True)
                return 2
        print("PASS: extracted Phosh lifecycle functions; real GLib timers/GObject signals.")
        print("LIMITATION: GTK widget lifecycle and desktop resolution are thin fixtures; no compositor run.")
        if baseline_incomplete:
            print("INCOMPLETE: fixed builds passed, but baseline abort checks need a separate rerun.")
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
