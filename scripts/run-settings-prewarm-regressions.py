#!/usr/bin/env python3
"""Apply the Settings patch to pristine GNOME 50.4 source and test its C lifecycle.

Usage: python3 scripts/run-settings-prewarm-regressions.py /path/to/cc-application.c
Requires patch, a C compiler, pkg-config, and gio-2.0. No display or device needed.
"""

import argparse
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile


def function(source, name):
    match = re.search(r"^static (?:void|gboolean|int)\n" + name + r" \(", source, re.M)
    if not match:
        raise AssertionError(f"Missing production function: {name}")
    # These selected functions have balanced braces, including in comments/strings.
    start = source.index("{", match.start())
    depth = 1
    end = start + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[match.start():end]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Pristine GNOME 50.4 cc-application.c")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory(prefix="pinecone-settings-regression-") as directory:
        work = Path(directory)
        (work / "shell").mkdir()
        target = work / "shell/cc-application.c"
        shutil.copyfile(args.source, target)
        subprocess.run([
            "patch", "--batch", "--fuzz=0", "-p1", "-i",
            str(root / "patches/gnome-control-center-pinecone-prewarm.patch"),
        ], cwd=work, check=True)
        source = target.read_text()
        declarations = re.search(
            r"typedef enum\n\{.*?\} PineconePrewarmState;.*?struct _CcApplication\n\{.*?\n\};",
            source, re.S,
        )
        assert declarations, "Missing prewarm state and application fields"
        (work / "settings-types.inc").write_text(declarations.group())
        names = [
            "cc_application_ensure_window", "pinecone_write_prewarm_ready_file",
            "pinecone_release_prewarm", "pinecone_cancel_prewarm",
            "pinecone_finish_prewarm", "pinecone_start_prewarm",
            "cc_application_command_line", "cc_application_quit",
            "cc_application_activate", "cc_application_shutdown", "cc_application_finalize",
            "launch_panel_activated", "launch_single_panel_mode_activated",
        ]
        (work / "settings-lifecycle.inc").write_text(
            "\n\n".join(function(source, name) for name in names) + "\n"
        )
        assert 'application_class->shutdown = cc_application_shutdown;' in source
        assert 'application_class->activate = cc_application_activate;' in source
        assert 'object_class->finalize = cc_application_finalize;' in source
        assert '{ "pinecone-prewarm", 0, G_OPTION_FLAG_HIDDEN, G_OPTION_ARG_NONE,' in source
        flags = shlex.split(subprocess.check_output(
            ["pkg-config", "--cflags", "--libs", "gio-2.0"], text=True,
        ))
        compiler = shlex.split(os.environ.get("CC", "cc"))
        sdk = []
        if sys.platform == "darwin":
            sdk = ["-isysroot", subprocess.check_output(
                ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True,
            ).strip()]
        sanitizers = []
        if os.environ.get("PINECONE_SETTINGS_SANITIZERS") == "1":
            sanitizers = ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
        executable = work / "regression"
        subprocess.run(compiler + [
            "-std=c11", "-g", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter",
            *sdk, *sanitizers, "-I", str(work), str(root / "settings-prewarm-regression.c"),
            *flags, "-o", str(executable),
        ], check=True)
        subprocess.run([str(executable)], check=True, timeout=60, env={
            **os.environ, "G_DEBUG": "fatal-warnings",
            "PINECONE_SETTINGS_PREWARM_READY_FILE": str(work / "ready"),
        })


if __name__ == "__main__":
    main()
