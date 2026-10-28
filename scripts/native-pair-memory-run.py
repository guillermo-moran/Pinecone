#!/usr/bin/env python3
"""Frozen-baseline versus current-native correctness and opt-in serial timing.

Each version uses its own complete source/header snapshot and object files.
This is an integrated native comparison, NOT a pair-only or padding-only A/B.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--ubsan", action="store_true")
    parser.add_argument("--benchmark", action="store_true", help="parent-only serial timing")
    parser.add_argument("--contention-only", action="store_true", help="run only epoch/ticket checks and optional timing")
    parser.add_argument("--rounds", type=int, default=8)
    parser.add_argument("--steps", type=int, default=8000000)
    args = parser.parse_args()
    if args.steps < 1024 or args.steps % 8 or args.rounds < 1:
        parser.error("steps must be >=1024 and divisible by 8; rounds must be positive")
    if args.ubsan and args.benchmark:
        parser.error("run sanitizer correctness separately from timing")
    root = Path(__file__).resolve().parent.parent
    baseline = args.baseline.resolve()
    work = (args.output or Path(tempfile.mkdtemp(prefix="native-pair-memory-"))).resolve()
    if work.exists() and any(work.iterdir()):
        parser.error("output directory must be empty; preserve earlier raw evidence")
    work.mkdir(parents=True, exist_ok=True)
    sources = {}
    manifest = {}
    source_names = ["ARM64VizNative.c", "ARM64VizBlockCache.c", "ARM64VizGuestMemory.c",
                    "ARM64VizThreadedPrototype.c", "ARM64VizGuestMemoryInternal.h"]
    for label, origin in [("baseline", baseline), ("candidate", root / "Sources/ARM64VizNative")]:
        snapshot = work / f"{label}-source"
        (snapshot / "include").mkdir(parents=True)
        inputs = [origin / name for name in source_names] + sorted((origin / "include").glob("*.h"))
        before = {path: sha(path) for path in inputs}
        for path in inputs:
            target = snapshot / path.relative_to(origin)
            shutil.copy2(path, target)
            manifest[str(target)] = sha(target)
            if manifest[str(target)] != before[path]:
                raise SystemExit(f"source changed during snapshot: {path}; rerun into a fresh output directory")
        if any(sha(path) != before[path] for path in inputs):
            raise SystemExit(f"{label} changed during snapshot; rerun into a fresh output directory")
        manifest.update({str(path): digest for path, digest in before.items()})
        sources[label] = snapshot
    harnesses = {}
    for name in ["native-pair-memory-harness.c", "native-pair-memory-contention.c"]:
        harness = work / name
        shutil.copy2(root / "scripts" / name, harness)
        harnesses[name] = harness
        manifest[str(harness)] = sha(harness)
    shutil.copy2(__file__, work / "native-pair-memory-run.py")
    manifest[str(work / "native-pair-memory-run.py")] = sha(work / "native-pair-memory-run.py")
    (work / "hashes.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (work / "comparison.txt").write_text(
        "Frozen baseline versus snapshotted current native implementation. NOT pair-only or padding-only.\n"
        "Every translation unit and harness uses only its version's private/public headers and objects.\n"
        "Threaded prototype disabled explicitly, matching the original pair runner configuration.\n"
        "Contention writer models the write-ticket atomic, not a complete guest store.\n")
    log = []

    def run(command):
        command = list(map(str, command))
        print("+ " + " ".join(command), flush=True)
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        log.append("+ " + " ".join(command) + "\n" + result.stdout)
        (work / "commands.log").write_text("".join(log))
        print(result.stdout, end="", flush=True)
        if result.returncode:
            raise SystemExit(f"exit={result.returncode}; raw output: {work / 'commands.log'}")
        return result.stdout

    print(f"artifacts={work}", flush=True)
    (work / "compiler.txt").write_text(run(["clang", "--version"]))
    flags = ["-O1", "-g", "-fsanitize=undefined", "-fno-sanitize-recover=all"] if args.ubsan else ["-O3"]
    results, binaries = {}, {}
    kinds = ["contention"] if args.contention_only else ["pair", "contention"]
    for label, source in sources.items():
        common = ["clang", "-std=c11", "-pthread", *flags, "-DAVZ_THREADED_PROTOTYPE_ENABLE=0",
                  "-I", source / "include", "-I", source]
        object_dir = work / f"{label}-objects"
        object_dir.mkdir()
        objects = []
        for name in ["ARM64VizNative", "ARM64VizBlockCache", "ARM64VizGuestMemory", "ARM64VizThreadedPrototype"]:
            output = object_dir / (name + ".o")
            run([*common, "-c", source / (name + ".c"), "-o", output])
            objects.append(output)
            manifest[str(output)] = sha(output)
        for kind in kinds:
            name = "native-pair-memory-harness.c" if kind == "pair" else "native-pair-memory-contention.c"
            binary = work / f"{label}-{kind}"
            run([*common, "-Wall", "-Wextra", "-Werror", harnesses[name], *objects, "-lm", "-o", binary])
            binaries[label, kind] = binary
            manifest[str(binary)] = sha(binary)
            (work / "hashes.json").write_text(json.dumps(manifest, indent=2) + "\n")
            results[label, kind] = run([binary])
            (work / f"{label}-{kind}-correctness.txt").write_text(results[label, kind])
            probe = "--probe" if kind == "pair" else "--layout"
            (work / f"{label}-{kind}-probe.txt").write_text(run([binary, probe]))
    for kind in kinds:
        if results["baseline", kind] != results["candidate", kind]:
            raise SystemExit(f"FAIL {kind} baseline/candidate deterministic output mismatch")
    if not args.benchmark:
        return
    samples, checksums, raw = {}, {}, []
    for n in range(args.rounds):
        order = ["baseline", "candidate"] if n % 2 == 0 else ["candidate", "baseline"]
        for label in order:
            output = "".join(run([binaries[label, kind], "--benchmark", args.steps]) for kind in kinds)
            raw.append(f"version={label} round={n + 1}\n{output}")
            (work / "benchmark.txt").write_text("".join(raw))
            for line in output.splitlines():
                row = dict(field.split("=", 1) for field in line.split())
                name = row["workload"]
                state = {key: value for key, value in row.items() if key != "ns"}
                if name in checksums and checksums[name] != state:
                    raise SystemExit(f"FAIL benchmark state/retirement mismatch: {name}")
                checksums[name] = state
                samples.setdefault(name, {}).setdefault(label, []).append(int(row["ns"]))
    summary = []
    for name, sample in samples.items():
        b, c = statistics.median(sample["baseline"]), statistics.median(sample["candidate"])
        summary.append(f"{name} baseline_median_ns={b:.0f} candidate_median_ns={c:.0f} change_percent={(c / b - 1) * 100:+.2f}")
    (work / "summary.txt").write_text("\n".join(summary) + "\n")
    print("\n".join(summary))


if __name__ == "__main__":
    main()
