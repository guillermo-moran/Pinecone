#!/usr/bin/env python3
"""Summarize the alternating runner log; values are ns per worker iteration."""
import csv
import statistics
import sys
from collections import defaultdict

samples = defaultdict(list)
version = None
with open(sys.argv[1], encoding="utf-8") as stream:
    for line in stream:
        if line.startswith("version="):
            version = line.split()[0].split("=", 1)[1]
        elif version and "," in line:
            mode, threads, sharing, iterations, ns, checksum, failures = next(csv.reader([line]))
            samples[(mode, threads, sharing, version)].append(float(ns))

print("mode,threads,sharing,runs,baseline_median_ns,current_median_ns,change_percent,baseline_min_max,current_min_max")
for mode, threads, sharing in dict.fromkeys(key[:3] for key in samples):
    baseline = samples[(mode, threads, sharing, "baseline")]
    current = samples[(mode, threads, sharing, "current")]
    assert baseline and len(baseline) == len(current)
    before, after = statistics.median(baseline), statistics.median(current)
    print(f"{mode},{threads},{sharing},{len(baseline)},{before:.3f},{after:.3f},"
          f"{(after / before - 1) * 100:+.1f},"
          f"{min(baseline):.3f}..{max(baseline):.3f},"
          f"{min(current):.3f}..{max(current):.3f}")
