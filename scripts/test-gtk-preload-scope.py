#!/usr/bin/env python3
"""Bounded libc-only scope tests; on Linux also verify real LD_PRELOAD loading."""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile


def run(command, **kwargs):
    subprocess.run([str(part) for part in command], check=True, timeout=20, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sanitizers", action="store_true", help="enable nonrecovering UBSan")
    args = parser.parse_args()
    source = Path(__file__).resolve().parent
    flags = ["-std=c11", "-O1", "-g", "-Wall", "-Wextra", "-Werror"]
    if args.sanitizers:
        flags += ["-fsanitize=undefined", "-fno-sanitize-recover=all"]
    cc = shlex.split(os.environ.get("CC", "cc")) + flags
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("PINECONE_GTK_", "PC_SCOPE_")) and key != "LD_PRELOAD"}
    with tempfile.TemporaryDirectory(prefix="gtk-preload-scope-") as tmp:
        tmp = Path(tmp)
        test = tmp / "scope-test"
        launcher = tmp / "profile-exec"
        run(cc + [source / "gtk-preload-scope-regression.c", "-o", test])
        run(cc + ["-DPINECONE_PROFILE_LAUNCHER", source / "guest-gtk-latency.c", "-o", launcher])
        run([test], env=env)
        env.update(PINECONE_GTK_LATENCY="1")
        if sys.platform.startswith("linux"):
            probe = tmp / "diagnostic.so"
            retained = tmp / "retained.so"
            for output, kind in [(probe, 1), (retained, 2)]:
                run(cc + ["-fPIC", "-shared", f"-DPC_SCOPE_FIXTURE={kind}",
                          source / "gtk-preload-scope-regression.c", "-o", output])
            env.update(PC_SCOPE_LOG=str(tmp / "loads.log"))
        else:
            # Darwin ignores LD_PRELOAD: run the real policy in the target,
            # but do not describe this as ELF loader/dependency coverage.
            probe = "/usr/local/lib/libpinecone-gtk-latency.so"
            retained = "/usr/lib/libpinecone-pixman.so"
            env.update(PC_SCOPE_EMULATE="1")
            print("SKIP real ELF loader test on non-Linux; target invokes actual header policy", flush=True)
        commit = "/usr/local/lib/pinecone-text-insertion/libpinecone-text-commit.so"
        env.update(PINECONE_GTK_PROBE_TOKEN=str(probe),
                   PINECONE_GTK_PRELOAD=f"{retained}:{probe}:{commit}:{probe}",
                   PC_SCOPE_EXPECTED=str(retained))
        # Linux also loads a second harmless diagnostic under the exact commit
        # token's role, avoiding installs into /usr/local during this test.
        if sys.platform.startswith("linux"):
            extra = tmp / "commit.so"
            run(cc + ["-fPIC", "-shared", "-DPC_SCOPE_FIXTURE=3",
                      source / "gtk-preload-scope-regression.c", "-o", extra])
            env.update(PINECONE_GTK_PRELOAD=f"{retained}:{probe}:{extra}",
                       PINECONE_GTK_SCOPED_PRELOADS=str(extra))
        run([launcher, test, "--target"], env=env)
        if sys.platform.startswith("linux"):
            rows = [line.split() for line in (tmp / "loads.log").read_text().splitlines()]
            for kind, count in [("1", 1), ("2", 2), ("3", 1)]:
                assert sum(row[0] == kind for row in rows) == count, rows
            assert len({row[1] for row in rows if row[0] == "2"}) == 2, rows
            print("PASS real loader: probe/extra load only in parent; retained DSO in parent and child")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
