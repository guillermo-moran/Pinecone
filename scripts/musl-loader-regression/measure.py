#!/usr/bin/env python3
"""Isolated native-Linux startup measurement; never installs a loader."""

import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, text=True, capture_output=True, **kwargs)


def parse_stats(stderr):
    lines = [line for line in stderr.splitlines()
             if line.startswith("pinecone-musl-startup ")]
    if len(lines) != 1:
        raise AssertionError(f"expected one startup report: {stderr!r}")
    stats = dict((key, int(value)) for key, value in
                 (field.split("=") for field in lines[0].split()[1:]))
    assert stats["clock_ok"] == 1
    assert 0 < stats["entries"] <= stats["build_calls"] <= stats["selected"]
    assert stats["selected"] <= stats["visited"] <= stats["candidates"]
    for kind, count in (("build", "build_calls"), ("index", "index_lookups")):
        assert stats[kind + "_probes"] >= stats[count] > 0
        assert 0 < stats[kind + "_max"] <= stats["slots"]
    assert 0 < stats["index_hits"] <= stats["index_lookups"]
    assert stats["cache_hits"] <= stats["cache_lookups"]
    assert stats["cache_lookups"] == stats["index_lookups"] - stats["index_hits"]
    return stats


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("loaders", nargs="+", type=Path)
    parser.add_argument("--cc", default=os.environ.get("CC", "cc"))
    parser.add_argument("--runs", type=int, default=31)
    parser.add_argument("--exports", type=int, default=4096)
    parser.add_argument("--references", type=int, default=4096)
    parser.add_argument("--repeat", type=int, default=4)
    parser.add_argument("--hash", choices=("gnu", "sysv", "both"), default="gnu")
    args = parser.parse_args()
    if not (0 < args.references <= args.exports and args.repeat > 0 and args.runs > 0):
        parser.error("require 0 < references <= exports and positive repeat/runs")
    loaders = [str(path.resolve(strict=True)) for path in args.loaders]
    with tempfile.TemporaryDirectory(prefix="musl-measure-") as work:
        root = Path(work)
        # Spread references across the export set, with repeated relocations.
        indexes = [i * args.exports // args.references for i in range(args.references)]
        (root / "exports.c").write_text("\n".join(
            f"int measure_{i:06d}(void) {{ return {i}; }}"
            for i in range(args.exports)))
        (root / "main.c").write_text(
            "\n".join(f"extern int measure_{i:06d}(void);" for i in indexes)
            + "\nstatic int (*volatile refs[])(void) = {\n"
            + ",\n".join(f"measure_{i:06d}" for _ in range(args.repeat) for i in indexes)
            + "\n};\nint main(void) { unsigned long long sum = 0;\n"
            + "for (unsigned i = 0; i < sizeof refs / sizeof refs[0]; i++) sum += refs[i]();\n"
            + f"return sum != {sum(indexes) * args.repeat}ULL; }}\n")
        flags = ["-O2", "-Wall", "-Wextra", "-Werror", f"-Wl,--hash-style={args.hash}"]
        run([args.cc, *flags, "-fPIC", "-shared", str(root / "exports.c"),
             "-Wl,-soname,libmeasure.so", "-o", str(root / "libmeasure.so")])
        run([args.cc, *flags, "-fPIE", "-pie", str(root / "main.c"),
             "-L" + work, "-lmeasure", "-o", str(root / "check")])
        samples = {loader: [] for loader in loaders}
        env = dict(os.environ)
        env.pop("LD_PRELOAD", None)
        env.pop("LD_LIBRARY_PATH", None)
        for iteration in range(args.runs + 1):
            # Alternate order; the first iteration warms both loaders and files.
            for loader in loaders[::1 if iteration % 2 == 0 else -1]:
                command = [loader, "--library-path", work + ":/lib:/usr/lib",
                           str(root / "check")]
                if iteration == 0:
                    for disabled in (None, "0", "yes"):
                        env.pop("PINECONE_MUSL_STARTUP_STATS", None)
                        if disabled is not None:
                            env["PINECONE_MUSL_STARTUP_STATS"] = disabled
                        assert not run(command, env=env).stderr
                env["PINECONE_MUSL_STARTUP_STATS"] = "1"
                stats = parse_stats(run(command, env=env).stderr)
                if iteration:
                    samples[loader].append(stats)
        result = {"exports": args.exports, "references": args.references,
                  "repeat": args.repeat, "hash": args.hash, "runs": args.runs,
                  "loaders": {}}
        for loader, rows in samples.items():
            summary = dict(rows[0])
            for field in ("build_ns", "reloc_ns"):
                values = [row[field] for row in rows]
                summary[field] = {"median": statistics.median(values),
                                  "min": min(values), "max": max(values)}
            summary["build_mean_probe"] = rows[0]["build_probes"] / rows[0]["build_calls"]
            summary["index_mean_probe"] = rows[0]["index_probes"] / rows[0]["index_lookups"]
            result["loaders"][loader] = summary
        print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
