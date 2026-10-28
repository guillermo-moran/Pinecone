#!/usr/bin/env python3
"""Frozen-dependency native validation tests; timing is opt-in and parent-owned."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--ubsan", action="store_true")
    parser.add_argument("--reference-source", type=Path)
    parser.add_argument("--rounds", type=int, default=0)
    parser.add_argument("--iterations", type=int, default=10000)
    parser.add_argument("--case", action="append", dest="cases")
    args = parser.parse_args()
    if args.rounds < 0 or args.iterations < 1:
        parser.error("rounds must be nonnegative and iterations positive")
    root = Path(__file__).resolve().parent.parent
    work = (args.output or Path(tempfile.mkdtemp(prefix="native-validation-span-"))).resolve()
    work.mkdir(parents=True, exist_ok=True)
    if (work / "dependencies").exists():
        parser.error("output already contains a dependency snapshot; choose a new output")
    baseline = args.baseline.resolve()
    if work == baseline or baseline in work.parents:
        parser.error("output must not modify the baseline")
    dependencies = work / "dependencies"
    shutil.copytree(baseline, dependencies)
    candidate = work / "candidate.c"
    shutil.copy2(root / "Sources/ARM64VizNative/ARM64VizNative.c", candidate)
    if args.reference_source:
        shutil.copy2(args.reference_source, work / "previous.c")
    candidate_include = work / "candidate-include"
    shutil.copytree(root / "Sources/ARM64VizNative/include", candidate_include)
    harness = work / "native-validation-span-harness.c"
    shutil.copy2(root / "scripts/native-validation-span-harness.c", harness)
    shutil.copy2(Path(__file__), work / Path(__file__).name)
    manifest = {str(p.relative_to(work)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sorted(work.rglob("*")) if p.is_file()}
    (work / "sha256.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"artifacts={work}", flush=True)
    commands = []

    def execute(command, log):
        command = list(map(str, command))
        commands.append(command)
        (work / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=180)
        (work / log).write_text(result.stdout)
        print(f"{log} exit={result.returncode}\n{result.stdout}", end="", flush=True)
        return result

    execute(["clang", "--version"], "compiler.txt")
    flags = ["-O1", "-g", "-fsanitize=undefined", "-fno-sanitize-recover=all"] if args.ubsan else ["-O3"]
    sources = [("baseline", dependencies / "ARM64VizNative.c"), ("candidate", candidate)]
    if args.reference_source:
        sources.append(("previous", work / "previous.c"))
    for label, source in sources:
        include = dependencies / "include" if label == "baseline" else candidate_include
        command = ["clang", "-std=c11", *flags, "-DAVZ_THREADED_PROTOTYPE_ENABLE=0",
                   "-I", include, "-I", dependencies,
                   f'-DAVZ_VALIDATION_NATIVE_SOURCE="{source}"', harness,
                   dependencies / "ARM64VizBlockCache.c", dependencies / "ARM64VizGuestMemory.c",
                   "-lm", "-o", work / label]
        if execute(command, f"{label}-build.txt").returncode:
            raise SystemExit(1)
    cases = args.cases or ["budgets", "stale", "checkpoint", "recycling", "self-modifying", "callback-recycling", "exception", "timer", "counts", "unrelated", "lookup-epochs", "revalidation-boundaries"]
    results = {}
    for label, _ in sources:
        results[label] = {}
        for case in cases:
            result = execute([work / label, case], f"{label}-{case}.txt")
            results[label][case] = result.returncode
    (work / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    if any(results["candidate"].values()):
        raise SystemExit("Candidate regression failure; timings not run. See raw artifacts.")
    for index in range(args.rounds):
        order = ["baseline", "candidate"] if index % 2 == 0 else ["candidate", "baseline"]
        checksums = []
        for label in order:
            result = execute([work / label, "benchmark", args.iterations],
                             f"{label}-benchmark-{index + 1}.txt")
            if result.returncode:
                raise SystemExit(1)
            rows = [dict(field.split("=", 1) for field in line.split())
                    for line in result.stdout.splitlines()]
            checksums.append([(r["workload"], r["steps"], r["checksum"]) for r in rows])
        if checksums[0] != checksums[1]:
            raise SystemExit("Benchmark state/step mismatch")


if __name__ == "__main__":
    main()
