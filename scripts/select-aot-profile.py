#!/usr/bin/env python3
"""Export full native blocks from sampled CLI execution profiles for AOT.

Weights are conservative retained block-visit samples, NOT exact execution
counts. The native Space-Saving sampler's inherited collision weight is removed.
Code contents merge across relocations and vCPUs; no persisted address proves
that a native function is safe to run.
"""
import argparse
import json
from collections import Counter
from pathlib import Path


def records(report):
    yield from report.get("primaryHotPCs", [])
    yield from report.get("secondaryHotPCs", [])


def select(reports):
    selected = {}
    for report in reports:
        for record in records(report):
            source = record.get("instructions", [])
            if isinstance(source, str):
                source = source.split()
            words = tuple(f"{int(w, 16):08x}" for w in source)
            if not words or len(words) > 16:
                continue
            if any(len(w) != 8 for w in words):
                raise ValueError("profile contains non-uint32 instruction")
            samples = int(record.get("samples", 0))
            error = int(record.get("sampleError", 0))
            if samples < 0 or not 0 <= error <= samples:
                raise ValueError("invalid sample/error bound")
            # Old reports truncated blocks to four words. Require the new error
            # field as the full-block format marker rather than invent a suffix.
            if "sampleError" not in record:
                continue
            entry = selected.setdefault(words, {"words": list(words), "samples": 0,
                "sampleError": 0, "weight": 0, "pcs": set()})
            entry["samples"] += samples
            entry["sampleError"] += error
            entry["weight"] += samples - error
            entry["pcs"].add(record["pc"])
    result = []
    for entry in selected.values():
        entry["pcs"] = sorted(entry["pcs"])
        entry["sampledInstructionWeight"] = entry["weight"] * len(entry["words"])
        result.append(entry)
    return sorted(result, key=lambda entry: (-entry["sampledInstructionWeight"], entry["words"]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", nargs="+", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    candidates = select([json.loads(path.read_text()) for path in args.reports])
    args.output.write_text(json.dumps(candidates, indent=2) + "\n")
    lengths = Counter(len(entry["words"]) for entry in candidates)
    print(json.dumps({"candidates": len(candidates), "blockLengths": dict(lengths),
        "retainedBlockVisitSampleLowerBound": sum(e["weight"] for e in candidates),
        "sampledInstructionWeight": sum(e["sampledInstructionWeight"] for e in candidates)}, sort_keys=True))


if __name__ == "__main__":
    main()
