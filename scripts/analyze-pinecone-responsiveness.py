#!/usr/bin/env python3
"""Summarize bounded interaction traces; never mix host and guest clock domains."""
import argparse
import json
import math
import re
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
