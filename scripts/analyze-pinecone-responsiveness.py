#!/usr/bin/env python3
"""Summarize bounded interaction traces; never mix host and guest clock domains."""
import argparse
import json
import math
import re
from collections import Counter
from pathlib import Path


def distribution(values):
    values = sorted(value for value in values if math.isfinite(value) and value >= 0)
    if not values:
        return {"count": 0}
    return {"count": len(values), "p50Ms": values[math.ceil((len(values) - 1) * .5)],
            "p95Ms": values[math.ceil((len(values) - 1) * .95)], "maxMs": values[-1]}


def mappings_from_uart(text):
    mappings = []
    process = None
    expression = re.compile(r"^([0-9a-f]+)-([0-9a-f]+)\s+(\S+)\s+([0-9a-f]+)\s+\S+\s+\d+\s+(.+)$")
    for line in text.splitlines():
        if line.startswith("PINECONE_MAP:"):
            process = line.split(":", 2)[-1]
        match = expression.match(line)
        if process and match and "x" in match[3]:
            mappings.append((int(match[1], 16), int(match[2], 16), int(match[4], 16), process, match[5]))
    return mappings


def snapshot_counters(text):
    """Last power-of-two checkpoint per process; never sum cumulative samples."""
    latest = {}
    for line in text.splitlines():
        if not line.startswith("pinecone-pixman-shm: "):
            continue
        fields = dict(re.findall(r"(\w+)=(\d+)", line))
        required = {"pid", "total", "creates", "initial_bytes", "updates", "update_bytes",
                    "empty_updates", "direct_draws", "invalid", "budget_rejects",
                    "alloc_failures", "update_rejects", "releases"}
        if not required <= fields.keys() or fields.keys() - required - {"copy_calls"}:
            raise ValueError("Incomplete SHM diagnostic record")
        record = {key: int(value) for key, value in fields.items()}
        pid = record.pop("pid")
        previous = latest.get(pid)
        if previous and any(record[key] < previous[key] for key in record.keys() & previous.keys()):
            raise ValueError("SHM counters reset: analyze a single VM run")
        latest[pid] = record
    return latest


def input_admission(report):
    phases = {}
    for entry in report.get("inputAttribution", []):
        phase = entry.get("phase") or "unknown"
        values = phases.setdefault(phase, {"capture": [], "queue": [], "dispositions": Counter()})
        values["dispositions"][entry["disposition"]] += 1
        capture, queued, injected = (entry.get(key) for key in (
            "captureNanoseconds", "queuedNanoseconds", "injectedNanoseconds"))
        if capture is not None and queued is not None and queued >= capture:
            values["capture"].append((queued - capture) / 1e6)
        if queued is not None and injected is not None and injected >= queued:
            values["queue"].append((injected - queued) / 1e6)
    guest = {}
    conflicts = set()
    for event in report.get("guestGraphics", []):
        if event.get("version") != 2 or event.get("event") != "touch":
            continue
        key = (event.get("epoch"), event.get("inputSequence"))
        if None in key or 0 in key:
            continue
        if key in guest and guest[key] != event:
            conflicts.add(key)
        guest[key] = event
    return {
        "hostPhases": {phase: {"captureToQueueMs": distribution(values["capture"]),
            "queueToInjectionMs": distribution(values["queue"]),
            "dispositions": dict(values["dispositions"])} for phase, values in phases.items()},
        "guestPhases": dict(Counter(event.get("phase", "unknown") for key, event in guest.items()
                                    if key not in conflicts)),
        "conflictingGuestIdentities": len(conflicts),
        "note": "Independent bounded rings: injection is not delivery; counts do not prove end-to-end correspondence or lost taps.",
    }


def summarize(report, uart=""):
    interactions = report.get("interactions", [])
    host = {field: distribution([entry[field] for entry in interactions]) for field in (
        "queueToDeviceMilliseconds", "deviceToCommitMilliseconds", "commitToPublishMilliseconds",
        "publishToPresentMilliseconds", "totalMilliseconds")}
    frames = [entry for entry in report.get("guestGraphics", []) if entry["event"] == "present"]
    spans = {"inputToRender": [], "renderToSubmit": [], "submitToCommit": [], "commitToGuestPresent": []}
    consumed_inputs = set()
    for frame in frames:
        for label, start, end in (("renderToSubmit", "renderUs", "submitUs"),
                                  ("submitToCommit", "submitUs", "commitUs"),
                                  ("commitToGuestPresent", "commitUs", "guestUs")):
            if frame.get(start, 0) > 0 and frame.get(end, 0) >= frame[start]:
                spans[label].append((frame[end] - frame[start]) / 1000)
        timestamp = frame.get("inputUs", 0)
        if timestamp > 0 and timestamp not in consumed_inputs and frame.get("renderUs", 0) >= timestamp:
            consumed_inputs.add(timestamp)
            spans["inputToRender"].append((frame["renderUs"] - timestamp) / 1000)
    mappings = mappings_from_uart(uart)
    hotspots = []
    for entry in report.get("hotPCs", []) + report.get("secondaryHotPCs", []):
        pc = int(entry["pc"], 16)
        candidates = [{"process": process, "path": path, "fileOffset": hex(offset + pc - start)}
                      for start, end, offset, process, path in mappings if start <= pc < end]
        hotspots.append({**entry, "candidates": candidates})
    return {"host": host, "guest": {key: distribution(values) for key, values in spans.items()},
            "inputAdmission": input_admission(report), "shmCheckpoints": snapshot_counters(uart),
            "validatedGuestFrameStages": {field: distribution([
                entry[field] for entry in report.get("guestFrameStages", [])
                if entry.get(field) is not None]) for field in (
                    "renderToSubmitMilliseconds", "renderToSubmitCPUMilliseconds",
                    "submitToCommitMilliseconds", "submitToCommitCPUMilliseconds",
                    "commitToPresentCallbackMilliseconds")},
            "hotspots": hotspots,
            "notes": ["Guest spans are not causally matched to individual host touches.",
                      "Hot-PC counts are approximate; file offsets are not ELF symbol addresses.",
                      "Use at least ten completed interactions and identical profiling settings for comparisons."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--uart", type=Path)
    args = parser.parse_args()
    report = json.loads(args.report.read_text())
    uart = args.uart.read_text(errors="replace") if args.uart else ""
    print(json.dumps(summarize(report, uart), indent=2))


if __name__ == "__main__":
    main()
