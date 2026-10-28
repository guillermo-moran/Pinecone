#!/usr/bin/env python3
"""Compare two existing builds on an explicitly selected, disposable Simulator."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for data in iter(lambda: source.read(1024 * 1024), b""):
            result.update(data)
    return result.hexdigest()


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def process_samples():
    result = []
    for row in command("ps", "-axo", "pid=,time=,rss=,comm=").splitlines():
        fields = row.split(None, 3)
        if len(fields) != 4 or not fields[3].endswith("/Pinecone.app/Pinecone"):
            continue
        seconds = sum(float(value) * 60 ** index
                      for index, value in enumerate(reversed(fields[1].split(":"))))
        result.append(dict(pid=int(fields[0]), cpuSeconds=seconds, rssKiB=int(fields[2])))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--baseline-app", type=Path, required=True)
    parser.add_argument("--candidate-app", type=Path, required=True)
    parser.add_argument("--disk", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--order", nargs="+", choices=("baseline", "candidate"),
                        default=["baseline", "candidate", "candidate", "baseline"])
    args = parser.parse_args()
    bundle = "me.gmoran.pinecone"
    root = Path(__file__).resolve().parent.parent
    apps = dict(baseline=args.baseline_app.resolve(), candidate=args.candidate_app.resolve())
    for app in apps.values():
        if not (app / "Pinecone").is_file():
            parser.error(f"missing app executable: {app}")
    args.output.mkdir(parents=True, exist_ok=False)
    disk_hash = digest(args.disk)
    identity = dict(device=args.device, diskSHA256=disk_hash,
                    appSHA256={key: digest(app / "Pinecone") for key, app in apps.items()},
                    order=args.order,
                    vcpus=2, prototype=1, threadedMemory=0)
    (args.output / "identity.json").write_text(json.dumps(identity, indent=2))
    results = []
    for number, variant in enumerate(identity["order"], 1):
        subprocess.run(["xcrun", "simctl", "terminate", args.device, bundle],
                       capture_output=True, check=False)
        command("xcrun", "simctl", "install", args.device, str(apps[variant]))
        container = Path(command("xcrun", "simctl", "get_app_container", args.device, bundle, "data"))
        disk = container / "Library/Application Support/Pinecone/rootfs.ext4"
        if number == 1 and disk.exists():
            command("cp", "-c", str(disk), str(args.output / "original-rootfs.ext4"))
        replacement = disk.with_name("rootfs.native-comparison.ext4")
        command("cp", "-c", str(args.disk), str(replacement))
        os.replace(replacement, disk)
        if digest(disk) != disk_hash:
            raise RuntimeError("restored disk checksum mismatch")
        prefix = args.output / f"{number:02d}-{variant}"
        environment = dict(os.environ, PINECONE_SIMULATOR_UDID=args.device,
                           PINECONE_PROFILE_TIMEOUT_SECONDS="240",
                           PINECONE_PROFILE_INTERACTION_TRACE="1",
                           SIMCTL_CHILD_PINECONE_THREADED_PROTOTYPE="1",
                           SIMCTL_CHILD_PINECONE_THREADED_MEMORY="0")
        print(f"Run {number}/{len(identity['order'])}: {variant}", flush=True)
        samples = []
        started = time.monotonic()
        with prefix.with_suffix(".json").open("w") as stdout, prefix.with_suffix(".stderr").open("w") as stderr:
            process = subprocess.Popen(["bash", "scripts/profile-pinecone-phosh.sh"],
                                       cwd=root, env=environment, stdout=stdout, stderr=stderr)
            try:
                while process.poll() is None:
                    samples.append(dict(seconds=time.monotonic() - started, processes=process_samples()))
                    time.sleep(1)
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
        prefix.with_suffix(".samples.json").write_text(json.dumps(samples))
        for name in ("pinecone-performance.log", "pinecone-uart.log"):
            source = container / "Library/Caches" / name
            if source.exists():
                shutil.copyfile(source, prefix.with_suffix("." + name))
        result = dict(run=number, variant=variant, exitCode=process.returncode,
                      processAtReady=process_samples())
        if process.returncode == 0:
            metrics = json.loads(prefix.with_suffix(".json").read_text())
            result.update(elapsedMilliseconds=metrics["elapsedMilliseconds"],
                          execution=metrics["executionAtMilestones"],
                          prototype=metrics.get("threadedPrototypePrimary"))
        results.append(result)
        (args.output / "summary.json").write_text(json.dumps(results, indent=2))
        print(json.dumps(result), flush=True)
        if process.returncode:
            raise RuntimeError("profile failed; comparison stopped, evidence retained")


if __name__ == "__main__":
    main()
