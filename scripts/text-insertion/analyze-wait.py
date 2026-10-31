#!/usr/bin/env python3
"""Join bounded PCWAIT1 call metadata to validated PCEDIT1 per-edit stages."""
import argparse
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
from analyze import analyze

HOOKS = {"g_signal_emit", "g_object_notify_by_pspec", "gtk_application_inhibit",
         "gtk_application_uninhibit", "g_dbus_proxy_call_sync", "g_dbus_connection_call_sync",
         "g_dbus_connection_send_message_with_reply_sync", "g_poll", "g_cond_wait",
         "g_cond_wait_until"}


def analyze_wait(text):
    edits = analyze(text)
    processes = {}
    for line in text.splitlines():
        if not line.startswith("PCWAIT1 "):
            continue
        parts = line.split()
        fields = {}
        for item in parts[2:]:
            key, value = item.split("=", 1)
            if key in fields:
                raise ValueError("duplicate wait field")
            fields[key] = value
        pid = int(fields["pid"])
        proc = processes.setdefault(pid, {"summary": None, "calls": {}, "done": False})
        if proc["done"]:
            raise ValueError("wait records after done")
        if parts[1] == "summary":
            if proc["summary"] is not None or proc["calls"]:
                raise ValueError("duplicate/misordered wait summary")
            proc["summary"] = fields
        elif parts[1] == "call":
            ident = int(fields["id"])
            if proc["summary"] is None or ident in proc["calls"]:
                raise ValueError("missing wait summary or duplicate call")
            proc["calls"][ident] = fields
        elif parts[1] == "done":
            proc["done"] = True
        else:
            raise ValueError("unknown wait record")
    if not processes:
        raise ValueError("no wait metadata: missing preload, disabled, or incomplete exit")
    for pid, proc in processes.items():
        summary = proc["summary"]
        if not proc["done"] or summary is None or int(summary["records"]) != len(proc["calls"]):
            raise ValueError("truncated wait metadata")
        if int(summary["dropped"]) != 0:
            raise ValueError("wait metadata saturated: repeat a shorter capture")
        if pid not in edits:
            raise ValueError("wait metadata without matching edit process")
        remaining = dict(proc["calls"])
        for root in edits[pid]["edit_roots"]:
            for stage in root["stages"]:
                if stage["id"] in remaining:
                    if stage["name"] not in HOOKS:
                        raise ValueError("wait metadata attached to a non-hook span")
                    stage["call"] = remaining.pop(stage["id"])
                elif stage["name"] in HOOKS:
                    raise ValueError("hook span lacks call metadata")
        if remaining:
            raise ValueError("wait call has no matching edit span")
    if set(edits) != set(processes):
        raise ValueError("edit process lacks wait metadata")
    return edits


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    args = parser.parse_args()
    try:
        result = analyze_wait(args.log.read_text())
    except (ValueError, KeyError, IndexError, OSError) as error:
        parser.exit(1, f"invalid wait trace: {error}\n")
    print(json.dumps(result, indent=2))
