#!/usr/bin/env python3
"""Analyze complete PCEDIT1 captures, without summing nested inclusive spans."""
import argparse
from collections import defaultdict
import json
from pathlib import Path
from statistics import median


def analyze(text):
    processes = {}
    for line in text.splitlines():
        if not line.startswith("PCEDIT1 "):
            continue
        parts = line.split()
        kind = parts[1]
        fields = {}
        for item in parts[2:]:
            key, value = item.split("=", 1)
            if key in fields:
                raise ValueError("duplicate field")
            fields[key] = value if key == "name" else int(value)
        if any(value < 0 for key, value in fields.items() if key != "name"):
            raise ValueError("negative value")
        pid = fields["pid"]
        proc = processes.setdefault(pid, {"spans": [], "summary": None, "done": False})
        if proc["done"]:
            raise ValueError("records after done (or repeated PID)")
        if kind == "summary":
            if proc["summary"] is not None or proc["spans"]:
                raise ValueError("duplicate/misordered summary")
            proc["summary"] = fields
        elif kind == "span":
            if proc["summary"] is None:
                raise ValueError("span without summary")
            proc["spans"].append(fields)
        elif kind == "done":
            proc["done"] = True
        else:
            raise ValueError("unknown PCEDIT1 record")
    if not processes:
        raise ValueError("no trace (disabled, crash, or wrong binary)")
    output = {}
    for pid, proc in processes.items():
        summary, spans = proc["summary"], proc["spans"]
        if not proc["done"] or summary is None or summary["records"] != len(spans):
            raise ValueError("truncated capture")
        if summary["dropped"] or summary["limited"]:
            raise ValueError("bounded capture saturated; repeat a shorter experiment")
        by_id = {}
        children = defaultdict(list)
        roots = []
        for span in spans:
            ident, parent = span["id"], span["parent"]
            if ident != len(by_id) + 1 or span["complete"] != 1:
                raise ValueError("duplicate/misordered/incomplete span")
            if (span["start"] <= 0 or span["end"] < span["start"] or
                    span["cpu_start"] <= 0 or span["cpu_end"] < span["cpu_start"]):
                raise ValueError("invalid clock")
            if parent:
                if parent not in by_id:
                    raise ValueError("missing parent")
                outer = by_id[parent]
                if (span["edit"] != outer["edit"] or
                        not outer["start"] <= span["start"] <= span["end"] <= outer["end"] or
                        not outer["cpu_start"] <= span["cpu_start"] <= span["cpu_end"] <= outer["cpu_end"]):
                    raise ValueError("invalid nesting")
            else:
                roots.append(span)
                if span["edit"] != len(roots):
                    raise ValueError("invalid edit identity")
            siblings = children[parent]
            if siblings and siblings[-1]["end"] > span["start"]:
                raise ValueError("overlapping sibling spans")
            siblings.append(span)
            by_id[ident] = span
        if summary["edits"] != len(roots) or not roots:
            raise ValueError("no complete edits or missing edit roots")
        labels = defaultdict(lambda: defaultdict(list))
        per_edit = defaultdict(list)
        for span in spans:
            wall = span["end"] - span["start"]
            cpu = span["cpu_end"] - span["cpu_start"]
            residual = wall - sum(c["end"] - c["start"] for c in children[span["id"]])
            labels[span["name"]]["wall"].append(wall / 1e6)
            labels[span["name"]]["cpu"].append(cpu / 1e6)
            labels[span["name"]]["unattributed"].append(residual / 1e6)
            per_edit[span["edit"]].append({
                "id": span["id"], "parent": span["parent"], "name": span["name"],
                "inclusive_wall_ms": wall / 1e6, "guest_thread_cpu_ms": cpu / 1e6,
                "wall_outside_traced_children_ms": residual / 1e6,
            })
        output[pid] = {
            "edits": len(roots),
            "labels": {name: {"calls": len(values["wall"]),
                              "median_inclusive_wall_ms": median(values["wall"]),
                              "median_guest_thread_cpu_ms": median(values["cpu"]),
                              "median_wall_outside_traced_children_ms": median(values["unattributed"])}
                       for name, values in sorted(labels.items())},
            "edit_roots": [{"edit": s["edit"], "name": s["name"],
                            "start_ns": s["start"], "end_ns": s["end"],
                            "stages": per_edit[s["edit"]]} for s in roots],
        }
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    args = parser.parse_args()
    try:
        result = analyze(args.log.read_text())
    except (ValueError, KeyError, IndexError, OSError) as error:
        parser.exit(1, f"invalid trace: {error}\n")
    print(json.dumps(result, indent=2))
