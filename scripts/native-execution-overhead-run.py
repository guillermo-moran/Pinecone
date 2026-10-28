#!/usr/bin/env python3
"""Compare with an exact pre-edit native-source directory, never git HEAD.

All dependencies come from that snapshot so concurrent cache/memory changes do
not confound the executor comparison. No Swift, guest image, or UI builds.
"""
import argparse
import hashlib
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile


def run(command):
    print("+ " + " ".join(map(str, command)), flush=True)
    return subprocess.check_output(list(map(str, command)), text=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path, help="captured ARM64VizNative directory")
    parser.add_argument("--rounds", type=int, default=6)
    parser.add_argument("--steps", type=int, default=30000000)
    parser.add_argument("--ubsan", action="store_true")
    parser.add_argument("--workload", choices=["add64", "sub32", "flagged", "mixed", "memory", "simd", "generic", "cached-chain"])
    parser.add_argument("--output", type=Path, help="preserve binaries and result logs here")
    args = parser.parse_args()
    if args.rounds < 0 or args.steps < 1024:
        parser.error("rounds must be nonnegative and steps must be at least 1024")
    root = Path(__file__).resolve().parent.parent
    baseline = args.baseline.resolve()
    work = args.output or Path(tempfile.mkdtemp(prefix="arm64viz-execution-overhead-"))
    work.mkdir(parents=True, exist_ok=True)
    work = work.resolve()
    print(f"artifacts={work}")
    # Preserve the tested executor/harness; includes and linkage use frozen dependencies.
    candidate = work / "candidate.c"
    shutil.copy2(root / "Sources/ARM64VizNative/ARM64VizNative.c", candidate)
    harness = work / "native-execution-overhead-harness.c"
    shutil.copy2(root / "scripts/native-execution-overhead-harness.c", harness)
    shutil.copy2(Path(__file__), work / "native-execution-overhead-run.py")
    sources = {"baseline": baseline / "ARM64VizNative.c", "candidate": candidate}
    binaries = {}
    for label, source in sources.items():
        print(f"{label}_sha256={hashlib.sha256(source.read_bytes()).hexdigest()}")
        output = work / label
        flags = ["-O1", "-g", "-fsanitize=undefined", "-fno-sanitize-recover=all"] if args.ubsan else ["-O3"]
        command = ["clang", "-std=c11", *flags, "-I", baseline / "include", "-I", baseline,
                   f'-DAVZ_OVERHEAD_NATIVE_SOURCE="{source}"',
                   harness,
                   baseline / "ARM64VizBlockCache.c", baseline / "ARM64VizGuestMemory.c",
                   "-lm", "-o", output]
        print(run(command), end="")
        binaries[label] = output
    results = {label: run([binary]) for label, binary in binaries.items()}
    for label, result in results.items():
        print(f"{label}: {result}", end="")
        (work / f"{label}-correctness.txt").write_text(result)
    if results["baseline"] != results["candidate"]:
        raise SystemExit("FAIL: baseline/candidate state or checkpoint digest differs")
    if args.ubsan or not args.rounds:
        return
    timings, checksums, log = {}, {}, []
    for round_index in range(args.rounds):
        order = ["baseline", "candidate"] if round_index % 2 == 0 else ["candidate", "baseline"]
        for label in order:
            command = [binaries[label], "--benchmark", args.steps]
            if args.workload:
                command.append(args.workload)
            output = run(command)
            print(f"version={label} round={round_index + 1}\n{output}", end="", flush=True)
            log.append(f"version={label} round={round_index + 1}\n{output}")
            for line in output.splitlines():
                row = dict(field.split("=", 1) for field in line.split())
                name = row["workload"]
                timings.setdefault(name, {}).setdefault(label, []).append(float(row["seconds"]))
                checksum = (row["steps"], row["checksum"])
                if name in checksums and checksums[name] != checksum:
                    raise SystemExit(f"FAIL: {name} benchmark state/steps differ")
                checksums[name] = checksum
            (work / "benchmark.txt").write_text("".join(log))
    summary = []
    for name, samples in timings.items():
        before = statistics.median(samples["baseline"])
        after = statistics.median(samples["candidate"])
        line = f"{name}: baseline={before:.6f}s candidate={after:.6f}s time_change={(after / before - 1) * 100:+.2f}%"
        summary.append(line)
        print(line)
    (work / "summary.txt").write_text("\n".join(summary) + "\n")


if __name__ == "__main__":
    main()
