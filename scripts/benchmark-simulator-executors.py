#!/usr/bin/env python3
"""Benchmark executor flags on an explicitly selected disposable Simulator.

Restores --seed before every run. Never point this at a user's working device.
Readiness is a guest-reported milestone, not proof of semantic UI readiness.
"""
import argparse
from collections import Counter
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import shlex
import subprocess
import time


# Assembly, threaded C, threaded C memory. Never inherit executor defaults.
VARIANTS = {"established": (0, 0, 0), "threaded": (0, 1, 0),
            "memory": (0, 1, 1), "assembly": (1, 0, 0), "assembly-chain": (1, 0, 0),
            "assembly-bounded": (1, 0, 0)}
BUNDLE = "me.gmoran.pinecone"
CACHE_DIAGNOSTICS = {"off": "0", "counts": "1", "time": "time"}
OWNER_TELEMETRY = ("assemblyExecutorSecondaryByVCPU", "assemblyCachePrimary",
                   "assemblyCacheSecondaryByVCPU")
ARTIFACTS = ("pinecone-performance.json", "pinecone-performance.log", "pinecone-uart.log")
COUNTERS = ("primaryNativeSteps", "primaryFallbackSteps", "secondarySteps",
            "secondaryNativeSteps", "secondaryFallbackSteps")
GAPS = [
    "ps measures only the app process, not Simulator services or total host CPU",
    "CPU is cumulative at observer polling time, not exactly at guest readiness",
    "RSS is sampled, not peak footprint, allocation/cache growth or guest memory pressure",
    "secondary threaded statistics remain unavailable; owner-published cache snapshots are asynchronous, at most 1Hz",
    "firstVisibleFrame and guest readiness do not establish semantic UI completion",
]


def command(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def write_json(path, value):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")
    temporary.replace(path)


def read_object(path):
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError(f"{path}: expected a JSON object")
    return value


def read_manifest(path):
    manifest = read_object(path)
    if type(manifest.get("schemaVersion")) is not int or manifest["schemaVersion"] != 1:
        raise ValueError("manifest schemaVersion must be 1")
    if not isinstance(manifest.get("cacheDiagnostics"), str) or manifest["cacheDiagnostics"] not in CACHE_DIAGNOSTICS:
        raise ValueError("manifest cacheDiagnostics must declare off, counts or time")
    for key in ("appSHA256", "seedSHA256", "fingerprintSHA256", "kernelSHA256"):
        if not isinstance(manifest.get(key), str) or not re.fullmatch(r"[0-9a-f]{64}", manifest[key]):
            raise ValueError(f"manifest requires lowercase SHA-256: {key}")
    for key in ("sourceState", "compilerFlags", "guestPackages", "hostConditions", "inputProtocol"):
        if not isinstance(manifest.get(key), str) or not manifest[key].strip():
            raise ValueError(f"manifest requires a nonempty provenance string: {key}")
    return manifest


def verify_identity(seed, fingerprint, manifest, executable=None):
    for path, key in ((seed, "seedSHA256"), (fingerprint, "fingerprintSHA256"),
                      (executable, "appSHA256")):
        if path is not None and digest(path) != manifest[key]:
            raise ValueError(f"identity mismatch: {key} ({path})")


def settings_for(variant, post_ready_command="", cache_diagnostics="off"):
    assembly, proto, memory = VARIANTS[variant]
    return {
        "PINECONE_ASSEMBLY_CACHE_DIAGNOSTICS": CACHE_DIAGNOSTICS[cache_diagnostics],
        "PINECONE_ASSEMBLY_EXECUTOR": str(assembly),
        "PINECONE_ASSEMBLY_CHAINING": str(int(variant in ("assembly-chain", "assembly-bounded"))),
        "PINECONE_ASSEMBLY_BOUNDED": str(int(variant == "assembly-bounded")),
        "PINECONE_THREADED_PROTOTYPE": str(proto), "PINECONE_THREADED_MEMORY": str(memory),
        "PINECONE_VCPU_COUNT": "2", "PINECONE_EXPERIMENTAL_PARALLEL_VCPU": "1",
        "PINECONE_SIMULATOR_AUTORUN_COMMAND": "PINECONE_INTERACTION_TRACE=1 start-pinecone-phosh &",
        "PINECONE_INTERACTION_TRACE": "1", "PINECONE_SIMULATOR_SHOW_DISPLAY": "1",
        "PINECONE_SIMULATOR_WRITE_PERFORMANCE_METRICS": "1", "PINECONE_SIMULATOR_DUMP_UART": "1",
        "PINECONE_SIMULATOR_AUTO_UNLOCK": "0",
        "PINECONE_SIMULATOR_POST_READY_COMMAND": post_ready_command,
        "PINECONE_SIMULATOR_POST_READY_DELAY_MS": "15000",
        "PINECONE_SIMULATOR_HOT_PC_PROFILE": "0", "PINECONE_SIMULATOR_DUMP_PERFORMANCE": "0",
    }


def launch_environment(settings, inherited=None):
    inherited = os.environ if inherited is None else inherited
    environment = {k: v for k, v in inherited.items()
                   if not k.startswith(("SIMCTL_CHILD_PINECONE_", "PINECONE_"))}
    environment.update({"SIMCTL_CHILD_" + k: v for k, v in settings.items()})
    return environment


def number(value):
    return type(value) in (int, float) and math.isfinite(value) and value >= 0


def instrumentation_for(mode):
    return {"cacheDiagnostics": mode, "cohortKind": "clean" if mode == "off" else "attribution"}


def comparison_record(path, plan):
    """Match experimental conditions, deliberately permitting changed executable/source."""
    reference = read_object(path)
    prior_manifest = reference.get("manifest", {})
    if not isinstance(prior_manifest, dict):
        raise ValueError("comparison reference requires a manifest")
    for key in ("seedSHA256", "fingerprintSHA256", "kernelSHA256", "compilerFlags",
                "guestPackages", "cacheDiagnostics", "hostConditions", "inputProtocol"):
        if key not in prior_manifest or prior_manifest[key] != plan["manifest"][key]:
            raise ValueError(f"comparison mismatch: manifest.{key}")
    for key in ("schemaVersion", "device", "vcpus", "parallel", "timeoutSeconds", "idleSeconds",
                "instrumentation", "settings", "harnessSHA256"):
        if key not in reference or reference[key] != plan[key]:
            raise ValueError(f"comparison mismatch: {key}; collect a fresh matched baseline")
    order = reference.get("order")
    if not isinstance(order, list) or any(not isinstance(v, str) or v not in VARIANTS for v in order):
        raise ValueError("invalid comparison reference order")
    if Counter(order) != Counter(plan["order"]):
        raise ValueError("comparison requires equal attempt counts per executor")
    if bool(reference.get("completionFile")) != bool(plan["completionFile"]):
        raise ValueError("comparison cannot mix boot-only and semantic-observer runs")
    app_hash = prior_manifest.get("appSHA256")
    if not isinstance(app_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", app_hash):
        raise ValueError("comparison reference requires executable identity")
    return {"referenceIdentityPath": str(path.resolve()), "referenceIdentitySHA256": digest(path),
            "referenceAppSHA256": app_hash, "candidateAppSHA256": plan["manifest"]["appSHA256"],
            "referenceOrder": order, "candidateOrder": plan["order"],
            "note": "Contract match only, not proof of successful attempts, host stability or a speedup."}


def record_milestones(prefix, report, elapsed, seen):
    """Journal app milestones independently of readiness or semantic UI success."""
    for name, milliseconds in report.get("elapsedMilliseconds", {}).items():
        observation = {"milestone": name, "appElapsedMilliseconds": milliseconds,
                       "execution": report.get("executionAtMilestones", {}).get(name)}
        if name in seen:
            if seen[name] != observation:
                raise ValueError(f"milestone changed within one attempt: {name}")
            continue
        seen[name] = observation
        with (prefix / "milestone-observations.jsonl").open("a") as stream:
            stream.write(json.dumps({**observation, "observerElapsedSeconds": elapsed}, allow_nan=False) + "\n")


def check_execution_safety(parsed):
    for milestone, counts in parsed["execution"].items():
        if counts["primaryFallbackSteps"] or counts["secondaryFallbackSteps"]:
            raise ValueError(f"nonzero Swift fallback at milestone {milestone}")


def validate_owner_telemetry(report, variant, mode, ready):
    def snapshot(value, label):
        if not isinstance(value, dict) or any(not isinstance(k, str) or type(v) is not int or v < 0
                                              for k, v in value.items()):
            raise ValueError(f"invalid owner telemetry: {label}")

    for field in OWNER_TELEMETRY:
        value = report.get(field)
        if value is None:
            continue
        if field.endswith("ByVCPU"):
            if not isinstance(value, dict):
                raise ValueError(f"invalid per-vCPU telemetry: {field}")
            for cpu, stats in value.items():
                if not isinstance(cpu, str):
                    raise ValueError("vCPU IDs must remain strings")
                snapshot(stats, f"{field}.{cpu}")
                if field == "assemblyExecutorSecondaryByVCPU" and stats.get("enabled") != VARIANTS[variant][0]:
                    raise ValueError("secondary assembly executor flag mismatch")
                if field == "assemblyExecutorSecondaryByVCPU":
                    validate_chain_statistics(stats, variant)
        else:
            snapshot(value, field)
    primary = report.get("assemblyCachePrimary")
    secondary = report.get("assemblyCacheSecondaryByVCPU")
    if mode != "off" and ready and (not primary or not secondary):
        raise ValueError("cache diagnostics requested but primary/secondary telemetry missing")
    snapshots = ([primary] if primary is not None else []) + list((secondary or {}).values())
    for stats in snapshots:
        expected = {"enabled": int(mode != "off"), "timingEnabled": int(mode == "time")}
        if mode != "off":
            expected["compiled"] = 1
        if any(stats.get(k) != v for k, v in expected.items()):
            raise ValueError("cache diagnostics compiled/enabled/timing telemetry differs from requested instrumentation")
        if mode != "off" and "publishedHostNanoseconds" not in stats:
            raise ValueError("cache diagnostics publication timestamp missing")


def validate_chain_statistics(stats, variant):
    expected = int(variant in ("assembly-chain", "assembly-bounded"))
    if type(stats.get("chainEnabled")) is not int or stats["chainEnabled"] != expected:
        raise ValueError("assembly chaining flag mismatch or missing")
    for key in ("chainRuns", "chainVisits", "chainSteps"):
        if type(stats.get(key)) is not int or stats[key] < 0:
            raise ValueError("missing/invalid assembly chain counters")
        if not expected and stats[key] != 0:
            raise ValueError("disabled assembly chain recorded work")
    bounded = int(variant == "assembly-bounded")
    if type(stats.get("boundedEnabled")) is not int or stats["boundedEnabled"] != bounded:
        raise ValueError("bounded assembly flag mismatch or missing")
    for key, total in (("boundedRuns", "chainRuns"), ("boundedVisits", "chainVisits"),
                       ("boundedSteps", "chainSteps")):
        if type(stats.get(key)) is not int or not 0 <= stats[key] <= stats[total]:
            raise ValueError("missing/invalid bounded assembly counters")
        if not bounded and stats[key] != 0:
            raise ValueError("disabled bounded assembly recorded work")


def parse_report(report, variant, cache_diagnostics="off"):
    """Normalize telemetry without substituting primary counts for both vCPUs."""
    if not isinstance(report, dict) or not isinstance(report.get("elapsedMilliseconds"), dict):
        raise ValueError("report requires elapsedMilliseconds")
    milestones = report["elapsedMilliseconds"]
    if not all(number(value) for value in milestones.values()):
        raise ValueError("invalid milestone time")
    assembly, proto, memory = VARIANTS[variant]
    for key, expected in (("assemblyExecutorPrimary", {"enabled": assembly}),
                          ("threadedPrototypePrimary", {"enabled": proto, "memoryEnabled": memory})):
        stats = report.get(key)
        if not isinstance(stats, dict) or any(type(stats.get(k)) is not int or stats[k] != v
                                             for k, v in expected.items()):
            raise ValueError(f"executor flags differ or are missing: {key}")
        required = ("blocks", "steps", "boundaries", "faults") if key.startswith("assembly") else ("blocks", "steps")
        if any(type(stats.get(k)) is not int or stats[k] < 0 for k in required):
            raise ValueError(f"missing/invalid statistics: {key}")
        if not expected["enabled"] and stats["steps"] != 0:
            raise ValueError(f"disabled executor retired steps: {key}")
    validate_chain_statistics(report["assemblyExecutorPrimary"], variant)
    execution = report.get("executionAtMilestones", {})
    if not isinstance(execution, dict):
        raise ValueError("executionAtMilestones must be an object")
    for milestone, values in execution.items():
        if not isinstance(values, dict) or any(type(values.get(k)) is not int or values[k] < 0 for k in COUNTERS):
            raise ValueError(f"milestone {milestone} requires primary AND secondary execution counters")
    ready = "interactiveWorkloadReady"
    counts = execution.get(ready)
    if ready in milestones:
        if not isinstance(counts, dict) or any(type(counts.get(k)) is not int or counts[k] < 0 for k in COUNTERS):
            raise ValueError("readiness requires primary AND secondary execution counters")
    validate_owner_telemetry(report, variant, cache_diagnostics, ready in milestones)
    return {
        **{key: report.get(key) for key in OWNER_TELEMETRY},
        "milestones": milestones, "execution": execution,
        "guestReadySeconds": milestones.get(ready) / 1000 if ready in milestones else None,
        "firstVisibleFrameSeconds": milestones.get("firstVisibleFrame") / 1000
        if "firstVisibleFrame" in milestones else None,
        "readyCounters": counts,
        "combinedNativeStepsAtReady": counts["primaryNativeSteps"] + counts["secondaryNativeSteps"]
        if counts is not None and ready in milestones else None,
        "assemblyExecutorPrimary": report["assemblyExecutorPrimary"],
        "threadedPrototypePrimary": report["threadedPrototypePrimary"],
        "assemblyExecutorSecondary": report.get("assemblyExecutorSecondary"),
        "threadedPrototypeSecondary": report.get("threadedPrototypeSecondary"),
    }


def validate_paths(seed, fingerprint, data, output):
    """Reject aliases before any termination, disk restore or log deletion."""
    if not data.is_absolute():
        raise ValueError("Simulator data container must be an absolute path")
    data = data.resolve()
    if not data.is_dir():
        raise ValueError("Simulator data container must already exist")
    disk_dir = data / "Library/Application Support/Pinecone"
    cache = data / "Library/Caches"
    targets = [disk_dir, cache, disk_dir / "rootfs.ext4",
               disk_dir / "rootfs.benchmark.ext4", disk_dir / "rootfs.bundle-fingerprint",
               disk_dir / "rootfs.bundle-fingerprint.benchmark"]
    targets.extend(cache / name for name in ARTIFACTS)
    for path in targets:
        if path.is_symlink() or not path.resolve().is_relative_to(data):
            raise ValueError(f"unsafe container target: {path}")
    for source in (seed, fingerprint):
        if not source.is_file() or source.resolve().is_relative_to(data):
            raise ValueError("seed/fingerprint must be files outside the disposable container")
        for target in targets:
            if target.exists() and source.samefile(target):
                raise ValueError("seed/fingerprint aliases a mutable container target")
    if output.resolve().is_relative_to(data) or data.is_relative_to(output.resolve()):
        raise ValueError("output must be separate from the Simulator container")
    return disk_dir, cache


def sample(pid):
    fields = command("ps", "-p", str(pid), "-o", "time=,rss=,%cpu=").split()
    if len(fields) != 3:
        raise RuntimeError("Pinecone process disappeared")
    cpu_seconds = sum(float(v) * 60 ** i for i, v in enumerate(reversed(fields[0].split(":"))))
    return {"cpuSeconds": cpu_seconds, "rssKiB": int(fields[1]), "psCPUPercent": float(fields[2])}


def parse_completion(path, attempt_id, variant):
    value = read_object(path)
    if value.get("attemptId") != attempt_id or value.get("variant") != variant:
        raise ValueError("completion identity differs from this attempt")
    attempts = value.get("attempts")
    if not isinstance(attempts, list) or not attempts:
        raise ValueError("completion requires semantic attempts, not an empty sentinel")
    ids = set()
    for row in attempts:
        if not isinstance(row, dict):
            raise ValueError("invalid semantic attempt")
        for key in ("id", "workload", "expected", "observed", "evidence", "inputProtocol"):
            if not isinstance(row.get(key), str) or not row[key].strip():
                raise ValueError(f"semantic attempt requires {key}")
        if row["id"] in ids:
            raise ValueError("duplicate semantic attempt id")
        ids.add(row["id"])
        if row.get("outcome") not in ("success", "failure", "observer_timeout", "guest_timeout", "invalid_input"):
            raise ValueError("invalid semantic outcome")
        latency = row.get("latencyMilliseconds")
        if row["outcome"] == "success" and not number(latency):
            raise ValueError("semantic success requires measured latency")
        if latency is not None and not number(latency):
            raise ValueError("invalid semantic latency")
    return value


def terminate_for_restore(device, prefix):
    result = subprocess.run(["xcrun", "simctl", "terminate", device, BUNDLE],
                            capture_output=True, text=True)
    write_json(prefix / "terminate.json", {"returncode": result.returncode,
                                          "stdout": result.stdout, "stderr": result.stderr})
    # Do not restore a disk after an unclassified failure to stop its writer.
    not_running = "found nothing to terminate" in result.stderr.lower()
    if result.returncode and not not_running:
        raise RuntimeError(f"cannot confirm stopped app: {result.stderr.strip()}")


def run_attempt(args, manifest, number_index, variant, data, app):
    prefix = args.output / f"{number_index:02d}-{variant}"
    prefix.mkdir()
    settings = settings_for(variant, args.post_ready_command, args.cache_diagnostics)
    write_json(prefix / "settings.json", settings)
    result = {"attemptId": prefix.name, "variant": variant, "status": "started", "failure": None,
              "pid": None, "observedReadySeconds": None, "browserStart": None,
              "sampledPeakRSSMiB": None, "measurementGaps": GAPS,
              "instrumentation": instrumentation_for(args.cache_diagnostics)}
    write_json(prefix / "result.json", result)
    samples, cache, ready_at = [], None, None
    seen_milestones = {}
    logs_cleared = False
    stage = "preflight"
    try:
        disk_dir, cache = validate_paths(args.seed, args.fingerprint, data, args.output)
        if args.completion_file and args.completion_file.resolve().is_relative_to(data.resolve()):
            raise ValueError("completion file must be outside the Simulator container")
        verify_identity(args.seed, args.fingerprint, manifest, app / "Pinecone")
        stage = "terminate"
        terminate_for_restore(args.device, prefix)
        stage = "restore"
        disk_dir.mkdir(parents=True, exist_ok=True)
        replacement = disk_dir / "rootfs.benchmark.ext4"
        if replacement.exists():
            raise ValueError("stale restore file exists; inspect it before retrying")
        command("cp", "-c", str(args.seed), str(replacement))
        if digest(replacement) != manifest["seedSHA256"]:
            raise ValueError("disk restore hash mismatch")
        os.replace(replacement, disk_dir / "rootfs.ext4")
        # Replace rather than truncate any pre-existing hard-linked fingerprint.
        fingerprint_copy = disk_dir / "rootfs.bundle-fingerprint.benchmark"
        with fingerprint_copy.open("xb") as stream:
            stream.write(args.fingerprint.read_bytes())
        os.replace(fingerprint_copy, disk_dir / "rootfs.bundle-fingerprint")
        verify_identity(args.seed, args.fingerprint, manifest, app / "Pinecone")
        for name in ARTIFACTS:
            (cache / name).unlink(missing_ok=True)
        logs_cleared = True
        stage = "launch"
        started = time.monotonic()
        launch = command("xcrun", "simctl", "launch", args.device, BUNDLE,
                         env=launch_environment(settings), stderr=subprocess.STDOUT)
        (prefix / "launch.txt").write_text(launch + "\n")
        pid = int(launch.rsplit(":", 1)[1])
        result["pid"] = pid
        write_json(prefix / "result.json", result)
        print(f"START {prefix.name} pid={pid}", flush=True)
        stage = "observe"
        while time.monotonic() - started < args.timeout:
            elapsed = time.monotonic() - started
            row = sample(pid)
            row["elapsedSeconds"] = elapsed
            samples.append(row)
            write_json(prefix / "samples.json", samples)
            report_path = cache / "pinecone-performance.json"
            try:
                report = read_object(report_path)
            except (FileNotFoundError, json.JSONDecodeError):
                report = None
            uart = cache / "pinecone-uart.log"
            if result["browserStart"] is None and uart.exists() and "PINECONE_FIREFOX_BENCHMARK_START" in uart.read_text(errors="replace").splitlines():
                result["browserStart"] = {"elapsedSeconds": elapsed, "wallTime": time.time()}
                write_json(prefix / "browser-start.json", result["browserStart"])
            if report is not None:
                write_json(prefix / "latest-report.json", report)
                with (prefix / "owner-telemetry.jsonl").open("a") as stream:
                    stream.write(json.dumps({"elapsedSeconds": elapsed,
                                             **{key: report.get(key) for key in OWNER_TELEMETRY}},
                                            allow_nan=False) + "\n")
                parsed = parse_report(report, variant, args.cache_diagnostics)
                record_milestones(prefix, report, elapsed, seen_milestones)
                result["latestTelemetry"] = parsed
                if ready_at is None and parsed["guestReadySeconds"] is not None:
                    ready_at = elapsed
                    result.update(parsed)
                    result["observedReadySeconds"] = ready_at
                    result["cpuSecondsAtReadyObservation"] = row["cpuSeconds"]
                    result["meanAppCPUPercentToReadyObservation"] = 100 * row["cpuSeconds"] / ready_at if ready_at else None
                    write_json(prefix / "ready.json", report)
                    counts = parsed["readyCounters"]
                    if counts["primaryFallbackSteps"] or counts["secondaryFallbackSteps"]:
                        raise ValueError("nonzero Swift fallback at readiness")
                    if VARIANTS[variant][0] and not parsed["assemblyExecutorPrimary"]["steps"]:
                        raise ValueError("assembly enabled but no primary assembly execution observed")
                    if variant in ("assembly-chain", "assembly-bounded") and not parsed["assemblyExecutorPrimary"]["chainSteps"]:
                        raise ValueError("assembly chaining enabled but no primary chain execution observed")
                    if variant == "assembly-bounded" and not parsed["assemblyExecutorPrimary"]["boundedSteps"]:
                        raise ValueError("bounded assembly enabled but no primary bounded execution observed")
                    command("xcrun", "simctl", "io", args.device, "screenshot", str(prefix / "ready.png"))
                    print(f"READY {prefix.name}: {parsed['guestReadySeconds']:.3f}s (guest milestone only)", flush=True)
                check_execution_safety(parsed)
            # An observer file cannot substitute for the readiness milestone.
            if ready_at is not None:
                if args.completion_file and args.completion_file.exists():
                    shutil.copyfile(args.completion_file, prefix / "completion.json")
                    completion = parse_completion(prefix / "completion.json", prefix.name, variant)
                    result["semanticAttempts"] = completion["attempts"]
                    if any(row["outcome"] != "success" for row in completion["attempts"]):
                        raise ValueError("semantic interaction failures; see retained completion.json")
                    break
                if not args.completion_file and elapsed >= ready_at + args.idle_seconds:
                    break
            time.sleep(1)
        else:
            raise TimeoutError("readiness timeout" if ready_at is None else "observer deadline expired (not guest timeout)")
        result["status"] = "observed"
    except (Exception, KeyboardInterrupt) as error:
        result.update(status="failed", failure=f"{type(error).__name__}: {error}", failureStage=stage)
        if isinstance(error, subprocess.CalledProcessError):
            result["commandOutput"] = error.output
    finally:
        # Archive before another attempt can clear the app's rolling telemetry.
        archive_errors = []
        if logs_cleared:
            for name in ARTIFACTS:
                try:
                    source = cache / name
                    if source.exists():
                        shutil.copyfile(source, prefix / name)
                except OSError as error:
                    archive_errors.append(f"{name}: {error}")
        if args.completion_file and args.completion_file.exists():
            try:
                shutil.copyfile(args.completion_file, prefix / "completion.json")
            except OSError as error:
                archive_errors.append(f"completion: {error}")
        try:
            verify_identity(args.seed, args.fingerprint, manifest, app / "Pinecone")
        except (OSError, ValueError) as error:
            result["identityError"] = str(error)
            result.update(status="failed", failure=result["failure"] or str(error))
        if archive_errors:
            result["archiveErrors"] = archive_errors
            result.update(status="failed", failure=result["failure"] or "artifact archival failed")
        result["sampledPeakRSSMiB"] = max((s["rssKiB"] / 1024 for s in samples), default=None)
        write_json(prefix / "samples.json", samples)
        write_json(prefix / "result.json", result)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--seed", type=Path, required=True)
    parser.add_argument("--fingerprint", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True,
                        help="Frozen identity/provenance JSON; see docs/phase7-benchmark-protocol.md")
    parser.add_argument("--compare-to", type=Path,
                        help="Reference cohort identity.json; enforce matching conditions across different builds")
    parser.add_argument("--cache-diagnostics", choices=CACHE_DIAGNOSTICS, default="off",
                        help="Separate attribution runs only: counts or preparation timing; default off")
    parser.add_argument("--confirm-disposable-device",
                        help="Repeat the exact disposable device UUID to authorize termination/disk restore")
    parser.add_argument("--plan-only", action="store_true",
                        help="Validate local inputs and print plan; no simctl or output writes")
    parser.add_argument("--order", nargs="+", choices=VARIANTS, required=True)
    parser.add_argument("--timeout", type=float, default=240)
    parser.add_argument("--idle-seconds", type=float, default=15)
    parser.add_argument("--post-ready-command", default="")
    parser.add_argument("--firefox-blank", action="store_true",
                        help="Launch normal Firefox with bundled preferences in a fresh /tmp profile")
    parser.add_argument("--firefox-local", action="store_true",
                        help="Use a small local HTML/input fixture instead of about:blank")
    parser.add_argument("--completion-file", type=Path,
                        help="Wait for this new observer-written file instead of the idle interval")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", args.device):
        parser.error("device must be an explicit UUID, never 'booted'")
    if not args.plan_only and args.confirm_disposable_device != args.device:
        parser.error("repeat --device UUID in --confirm-disposable-device to authorize destructive restore")
    if not number(args.timeout) or args.timeout == 0 or not number(args.idle_seconds):
        parser.error("timeout must be positive and idle-seconds nonnegative, both finite")
    if args.firefox_blank or args.firefox_local:
        if args.post_ready_command:
            parser.error("firefox-blank and post-ready-command are mutually exclusive")
        if args.firefox_blank and args.firefox_local:
            parser.error("select only one Firefox fixture")
        page = ('<!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">'
                '<title>Pinecone benchmark</title><body style="font:24px sans-serif;margin:20px">'
                '<h1>Pinecone benchmark</h1><p id="status">Local page ready</p>'
                '<button style="font:24px sans-serif;padding:15px" '
                'onclick="document.getElementById(\'status\').textContent=\'Tap received\'">Test tap</button>'
                '<p><input style="font:24px sans-serif;width:95%" placeholder="Type here"></p>'
                '<div style="height:1500px">Scroll area</div><p>End of page</p>')
        fixture_command = ("printf %s " + shlex.quote(page) +
                           " >/tmp/pinecone-benchmark.html; ") if args.firefox_local else ""
        url = "file:///tmp/pinecone-benchmark.html" if args.firefox_local else "about:blank"
        browser_exec = ('exec busybox env "$@" MOZ_ENABLE_WAYLAND=1 '
                        'GDK_BACKEND=wayland GTK_IM_MODULE=wayland '
                        'firefox --no-remote --profile /tmp/pinecone-firefox-benchmark ' + url)
        args.post_ready_command = (
            'p=$(busybox pidof phosh); '
            'umask 077; mkdir -p /tmp/pinecone-firefox-benchmark; '
            'cp /usr/share/pinecone/browser/firefox-user.js /tmp/pinecone-firefox-benchmark/user.js; '
            + fixture_command +
            'printf "\\nPINECONE_FIREFOX_BENCHMARK_START\\n"; '
            'busybox xargs -0 sh -c ' + shlex.quote(browser_exec) +
            ' sh </proc/$p/environ >/tmp/pinecone-firefox-benchmark.log 2>&1 &'
        )
    if args.completion_file and (len(args.order) != 1 or args.completion_file.exists()):
        parser.error("completion-file requires one run and a previously nonexistent file")
    if args.completion_file and args.completion_file.is_symlink():
        parser.error("completion-file must not be a symlink")
    if args.output.exists() or args.output.is_symlink():
        parser.error("output must not already exist; failed attempts are never overwritten")
    try:
        manifest = read_manifest(args.manifest)
        if manifest["cacheDiagnostics"] != args.cache_diagnostics:
            raise ValueError("manifest cacheDiagnostics differs from --cache-diagnostics; use a separate attribution manifest")
        verify_identity(args.seed, args.fingerprint, manifest)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    plan = {"schemaVersion": 1, "device": args.device, "manifest": manifest,
            "harnessSHA256": digest(Path(__file__)),
            "instrumentation": instrumentation_for(args.cache_diagnostics),
            "order": args.order, "vcpus": 2, "parallel": True,
            "timeoutSeconds": args.timeout, "idleSeconds": args.idle_seconds,
            "completionFile": str(args.completion_file) if args.completion_file else None,
            "seed": str(args.seed.resolve()), "fingerprint": str(args.fingerprint.resolve()),
            "settings": {v: settings_for(v, args.post_ready_command, args.cache_diagnostics) for v in args.order},
            "measurementGaps": GAPS,
            "note": "Cold guest processes; identical persistent seed; host file caches not flushed. No performance claim."}
    if args.compare_to:
        try:
            plan["comparison"] = comparison_record(args.compare_to, plan)
        except (OSError, ValueError) as error:
            parser.error(str(error))
    if args.plan_only:
        print(json.dumps(plan, indent=2))
        return 0
    # Resolve container boundaries before writing even the cohort directory.
    try:
        data = Path(command("xcrun", "simctl", "get_app_container", args.device, BUNDLE, "data"))
        app = Path(command("xcrun", "simctl", "get_app_container", args.device, BUNDLE, "app"))
        validate_paths(args.seed, args.fingerprint, data, args.output)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.error(str(error))
    args.output.mkdir(parents=True, exist_ok=False)
    write_json(args.output / "identity.json", plan)
    results = [{"attemptId": f"{i:02d}-{v}", "variant": v, "status": "notAttempted"}
               for i, v in enumerate(args.order, 1)]
    write_json(args.output / "summary.json", results)
    try:
        verify_identity(args.seed, args.fingerprint, manifest, app / "Pinecone")
        plan.update(host=command("sw_vers"), hardware=command("sysctl", "-n", "machdep.cpu.brand_string"),
                    simulator=command("xcrun", "simctl", "list", "devices", "--json"),
                    appSHA256=digest(app / "Pinecone"), seedSHA256=manifest["seedSHA256"],
                    fingerprintSHA256=manifest["fingerprintSHA256"])
        if args.compare_to:
            if digest(args.compare_to) != plan["comparison"]["referenceIdentitySHA256"]:
                raise ValueError("comparison reference changed after preflight")
            reference = read_object(args.compare_to)
            for key in ("host", "hardware"):
                if reference.get(key) != plan[key]:
                    raise ValueError(f"comparison mismatch: actual {key}")
        write_json(args.output / "identity.json", plan)
        for index, variant in enumerate(args.order, 1):
            result = run_attempt(args, manifest, index, variant, data, app)
            results[index - 1] = result
            write_json(args.output / "summary.json", results)
            print(json.dumps(result), flush=True)
            if result["failure"]:
                return 1
            # Final app remains active; the next attempt explicitly stops it.
            if index != len(args.order):
                time.sleep(5)
    except (Exception, KeyboardInterrupt) as error:
        write_json(args.output / "cohort-failure.json", {"failure": f"{type(error).__name__}: {error}"})
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
