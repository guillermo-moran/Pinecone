#!/usr/bin/env python3
"""Summarize guest GTK probe clocks without treating a paint as presentation."""
import argparse
import json
import re
from pathlib import Path

RECORD = re.compile(r"^PINECONE_GTK pid=(\d+) mono_us=(\d+) event=(\w+) seq=(\d+) length=(-?\d+)$")
FRAME_PREFIX = "PINECONE_GTK_FRAME "
FRAME_STAGES = {"frame", "update", "layout", "paint", "gsk_diff", "cairo_begin",
                "cairo_draw", "cairo_end", "texture_diff", "texture_download"}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate frame JSON key")
        result[key] = value
    return result


def frame_records(text):
    processes, last = {}, {}
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith(FRAME_PREFIX):
            continue
        record = json.loads(line[len(FRAME_PREFIX):], object_pairs_hook=unique_object)
        fields = {"version", "pid", "frame", "seqBegin", "seqEnd", "beginNs", "endNs", "valid"}
        if not isinstance(record, dict) or set(record) != fields | {"stages"}:
            raise ValueError("Invalid frame schema")
        if any(type(record[k]) is not int or record[k] < 0 for k in fields):
            raise ValueError("Invalid frame integer")
        if record["version"] != 1 or record["pid"] == 0 or record["valid"] not in (0, 1):
            raise ValueError("Invalid frame version, PID, or validity")
        pid = str(record["pid"])
        frames = processes.setdefault(pid, [])
        previous = last.get(pid)
        if previous is not None and record["frame"] <= previous["frame"]:
            raise ValueError("Duplicate or decreasing frame identity")
        last[pid] = record
        if not record["valid"]:
            frames.append({"frame": record["frame"], "valid": False})
            continue
        if (not record["beginNs"] or record["endNs"] < record["beginNs"] or
                (previous and previous["valid"] and record["beginNs"] < previous["endNs"]) or
                record["seqEnd"] < record["seqBegin"]):
            raise ValueError("Invalid frame clock or insertion order")
        stages = record["stages"]
        if not isinstance(stages, dict) or set(stages) != FRAME_STAGES:
            raise ValueError("Missing or unknown frame stages")
        for stage in stages.values():
            if (not isinstance(stage, dict) or set(stage) != {"calls", "wallNs", "threadNs"} or
                    any(type(v) is not int or v < 0 for v in stage.values()) or
                    (stage["calls"] == 0 and (stage["wallNs"] or stage["threadNs"]))):
                raise ValueError("Invalid frame stage")
        duration = record["endNs"] - record["beginNs"]
        if stages["frame"]["calls"] != 1 or stages["frame"]["wallNs"] != duration:
            raise ValueError("Frame endpoints disagree with duration")
        if any(stage["wallNs"] > duration for stage in stages.values()):
            raise ValueError("Stage exceeds frame duration")
        frames.append({
            "frame": record["frame"], "valid": True,
            "sequenceAtBegin": record["seqBegin"], "sequenceAtEnd": record["seqEnd"],
            "insertionChangedDuringFrame": record["seqBegin"] != record["seqEnd"],
            "beginGuestNs": record["beginNs"], "endGuestNs": record["endNs"],
            "stages": {name: {"calls": s["calls"], "wallMs": s["wallNs"] / 1e6,
                              "guestThreadMs": s["threadNs"] / 1e6}
                       for name, s in stages.items() if s["calls"]},
        })
    return processes


def summarize(text):
    processes = {}
    for line in text.splitlines():
        match = RECORD.fullmatch(line.strip())
        if not match:
            continue
        pid, when, event, seq, length = match.groups()
        events = processes.setdefault(pid, [])
        when = int(when)
        if when == 0 or (events and when < events[-1]["us"]):
            raise ValueError("Invalid or decreasing guest clock")
        events.append(dict(us=when, event=event, seq=int(seq), length=int(length)))
    results = {}
    for pid, events in processes.items():
        starts = [e for e in events if e["event"] == "exec"]
        if len(starts) > 1:
            raise ValueError("Multiple execs for one PID; split the captures")
        start = starts[0]["us"] if starts else 0
        milestones = {}
        inserts = {}
        for e in events:
            if e["us"] < start:
                continue
            kind, seq = e["event"], e["seq"]
            if kind in ("insert_begin", "insert_end", "before_paint", "after_paint"):
                item = inserts.setdefault(seq, {})
                if kind in item:
                    raise ValueError("Duplicate insertion event identity")
                item[kind] = e["us"]
                if kind == "insert_begin":
                    item["bytes"] = e["length"]
            else:
                milestones.setdefault(kind, e["us"])
        stages = {}
        for label, a, b in (
            ("execToConstructorMs", "exec", "constructor"),
            ("constructorToApplicationRunMs", "constructor", "application_run"),
            ("applicationRunToStartupEndMs", "application_run", "startup_end"),
            ("startupToActivateEndMs", "startup_end", "activate_end"),
            ("execToFirstAfterPaintMs", "exec", "first_after_paint"),
        ):
            if a in milestones and b in milestones and milestones[b] >= milestones[a]:
                stages[label] = (milestones[b] - milestones[a]) / 1000
        samples = []
        for seq, item in sorted(inserts.items()):
            sample = {"sequence": seq, "bytes": item.get("bytes")}
            for label, a, b in (("insertHandlerMs", "insert_begin", "insert_end"),
                                ("insertToBeforePaintMs", "insert_begin", "before_paint"),
                                ("paintCycleMs", "before_paint", "after_paint"),
                                ("insertToAfterPaintMs", "insert_begin", "after_paint")):
                if a in item and b in item and item[b] >= item[a]:
                    sample[label] = (item[b] - item[a]) / 1000
            samples.append(sample)
        results[pid] = {"milestonesGuestUs": milestones, "startup": stages, "insertions": samples}
    for pid, frames in frame_records(text).items():
        result = results.setdefault(pid, {"milestonesGuestUs": {}, "startup": {}, "insertions": []})
        result["frames"] = frames
    return {"processes": results, "notes": [
        "Guest monotonic timestamps only; do not subtract host touch timestamps.",
        "after-paint is GTK frame completion, not host display presentation.",
        "Only the latest insertion before a paint is paired; absent paints are not zero latency.",
        "Instrumented startup includes probe overhead; compare identical configurations.",
        "Frame stages are inclusive and overlap; never sum nested GSK stages with paint/frame.",
        "guestThreadMs is guest thread accounting, not host CPU time; wall minus thread is not a measured wait.",
        "Absent stages are unobserved, not zero cost; private GSK stages need the optional GTK source patch.",
        "Frame sequence is context, not proof that an insertion was rendered; changed-during-frame sequences are not paired.",
    ]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    args = parser.parse_args()
    print(json.dumps(summarize(args.log.read_text(errors="replace")), indent=2))
