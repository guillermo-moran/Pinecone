#!/usr/bin/env python3
"""Offline, conservative attribution of one Pinecone run's saved metrics/UART."""
import argparse
import hashlib
import json
from pathlib import Path


MAX_U64 = (1 << 64) - 1
INPUT_DISPOSITIONS = {
    "queued", "injectedUncorrelated", "expiredUncorrelated", "reset",
    "sequenceWrap", "coalesced", "droppedMotion", "rejected",
}


def uint(value, positive=False):
    return type(value) is int and int(positive) <= value <= MAX_U64


def records(report, name):
    value = report.get(name, [])
    if not isinstance(value, list) or any(not isinstance(x, dict) for x in value):
        raise ValueError(f"{name} must be an array of objects")
    return value


def uart_events(raw):
    """Mirror RS recovery; do not promote a truncated final line to an event."""
    result, issues = [], []
    for number, line in enumerate(raw.splitlines(keepends=True), 1):
        # bytes.splitlines deliberately does not treat RS as a line ending.
        payload = line.rsplit(b"\x1e", 1)[-1]
        if not payload.startswith(b"PINECONE_TRACE "):
            continue
        if not line.endswith(b"\n") or len(payload.rstrip(b"\r\n")) > 2048:
            issues.append(f"uart line {number}: truncated or oversized trace")
            continue
        try:
            event = json.loads(payload[len(b"PINECONE_TRACE "):])
            if not isinstance(event, dict):
                raise ValueError("not an object")
            result.append(event)
        except (ValueError, UnicodeError):
            issues.append(f"uart line {number}: malformed trace")
    return result, issues


def index_records(entries, key, label, issues):
    unique, conflicts = {}, set()
    for entry in entries:
        identity = key(entry)
        if identity is None:
            issues.append(f"{label}: invalid/missing identity")
            continue
        if identity in unique and unique[identity] != entry:
            conflicts.add(identity)
        unique[identity] = entry
    for identity in sorted(conflicts):
        issues.append(f"{label} {identity}: conflicting records; excluded")
        del unique[identity]
    return unique


def pair(entry, first, second):
    values = (entry.get(first), entry.get(second))
    return values if all(uint(x, positive=True) for x in values) else None


def host_key(entry):
    identity = entry.get("identity")
    return pair(identity, "epoch", "sequence") if isinstance(identity, dict) else None


def gap(transition, reason, status="unobserved_transition"):
    return {"transition": transition, "status": status, "reason": reason}


def span(transition, start, end, clock, divisor, cpu=None):
    if start is None or end is None:
        return gap(transition, "endpoint_not_recorded")
    if not uint(start) or not uint(end) or end < start:
        return gap(transition, "invalid_or_reversed_timestamp", "invalid_evidence")
    value = {"transition": transition, "status": "observed_delay",
             "clock": clock, "elapsedMs": (end - start) / divisor}
    if cpu is not None:
        if not uint(cpu):
            value["cpuEvidence"] = "invalid"
        else:
            # CPU accounting is a duration, not a timestamp in the monotonic domain.
            value["threadCpuMs"] = cpu / divisor
            value["cpuEvidence"] = "guest_thread_accounting_not_host_cost"
    return value


def cpu_delta(entry, start, end):
    a, b = entry.get(start), entry.get(end)
    if a is None and b is None:
        return None
    return b - a if uint(a) and uint(b) and b >= a else -1


def analyze(report, extra_guest=(), run_id="unspecified"):
    if not isinstance(report, dict):
        raise ValueError("metrics must be a JSON object")
    issues = []
    host = index_records(records(report, "inputAttribution"), host_key, "host input", issues)
    all_guest = records(report, "guestGraphics") + list(extra_guest)
    accepted = []
    for entry in all_guest:
        if (type(entry.get("version")) is not int or entry["version"] != 2 or
                entry.get("event") not in ("touch", "present", "dropped")):
            issues.append("guest record: unsupported version/event; excluded")
        else:
            accepted.append(entry)
    touches = index_records([x for x in accepted if x["event"] == "touch"],
                            lambda x: pair(x, "epoch", "inputSequence"), "guest touch", issues)
    frames = index_records([x for x in accepted if x["event"] != "touch"],
                           lambda x: pair(x, "epoch", "frameID"), "guest frame", issues)
    inputs, handlers, frame_results = [], [], []
    for identity, entry in sorted(host.items()):
        disposition = entry.get("disposition")
        capture = span("capture_to_host_queue", entry.get("captureNanoseconds"),
                       entry.get("queuedNanoseconds"), "host_monotonic_ns", 1e6)
        injection = span("host_queue_to_injection", entry.get("queuedNanoseconds"),
                         entry.get("injectedNanoseconds"), "host_monotonic_ns", 1e6)
        if not isinstance(disposition, str) or disposition not in INPUT_DISPOSITIONS:
            injection = gap("host_queue_to_injection", "unknown_disposition", "invalid_evidence")
        elif disposition in ("coalesced", "droppedMotion", "rejected"):
            injection = gap("host_queue_to_injection", disposition, "missing_transition")
            if entry.get("injectedNanoseconds") is not None:
                injection = gap("host_queue_to_injection", "disposition_conflicts_with_injection",
                                "invalid_evidence")
        inputs.append({"identity": {"epoch": identity[0], "sequence": identity[1]},
                       "phase": entry.get("phase"), "disposition": disposition,
                       "transitions": [capture, injection,
                           gap("injection_to_virtqueue_irq_linux_phoc",
                               "host_identity_not_carried_across_input_wire")]})
    for identity, entry in sorted(touches.items()):
        handlers.append({"identity": {"epoch": identity[0], "inputSequence": identity[1]},
                         "phase": entry.get("phase"), "touchID": entry.get("touchID"),
                         "transitions": [span("phoc_handler", entry.get("guestUs"),
                             entry.get("handlerEndUs"), "guest_monotonic_us", 1000,
                             entry.get("handlerCPUUs")),
                             gap("phoc_to_wayland_client_semantic_handler",
                                 "no_client_delivery_or_semantic_ack_identity")]})
    for identity, entry in sorted(frames.items()):
        if not uint(entry.get("outputID"), positive=True) or not uint(entry.get("sequence")) or entry["sequence"] > 0xffffffff:
            issues.append(f"guest frame {identity}: invalid outputID/sequence; excluded")
            continue
        item = {"identity": {"epoch": identity[0], "frameID": identity[1],
                             "outputID": entry["outputID"], "sequence": entry["sequence"]},
                "inputAcknowledgement": "unobserved", "inputAssociation": "none",
                "transitions": []}
        if entry["event"] == "dropped":
            reason = entry.get("reason", "unspecified")
            # Expired is emitted AFTER a successful present; eviction/reuse loses
            # bookkeeping. Only these explicit failures establish a missing stage.
            status = "missing_transition" if reason in ("aborted", "notPresented") else "unobserved_transition"
            transition = "render_to_commit" if reason == "aborted" else "frame_to_presented_callback"
            item["transitions"].append(gap(transition, reason, status))
        else:
            times = [entry.get(name) for name in ("renderUs", "submitUs", "commitUs", "guestUs")]
            recorded_times = [t for t in times if t is not None]
            if any(not uint(t) for t in recorded_times) or any(
                    a > b for a, b in zip(recorded_times, recorded_times[1:])):
                item["transitions"].append(gap("frame_pipeline", "invalid_or_reversed_timestamp", "invalid_evidence"))
            else:
                for label, start, end, cpu_start, cpu_end in (
                    ("render_to_submit", "renderUs", "submitUs", "renderCPUUs", "submitCPUUs"),
                    ("submit_to_commit", "submitUs", "commitUs", "submitCPUUs", "commitCPUUs"),
                    ("commit_to_guest_present_callback", "commitUs", "guestUs", None, None),
                ):
                    cpu = cpu_delta(entry, cpu_start, cpu_end) if cpu_start else None
                    item["transitions"].append(span(label, entry.get(start), entry.get(end),
                                                     "guest_monotonic_us", 1000, cpu))
            sequence = entry.get("inputSequence")
            if sequence is not None:
                item["inputAssociation"] = "unmatched"
                touch = touches.get((identity[0], sequence)) if uint(sequence, True) else None
                start = touch.get("guestUs") if touch else None
                end = touch.get("handlerEndUs") if touch else None
                render = entry.get("renderUs")
                if (entry.get("association") == "temporalOnly" and
                        all(uint(t) for t in (start, end, render, entry.get("inputUs"))) and
                        start == entry["inputUs"] and start <= end <= render and render - start <= 2_000_000):
                    item["inputAssociation"] = "temporalOnly"
                    item["temporalContext"] = {
                        "inputSequence": sequence, "handlerStartToRenderMs": (render - start) / 1000,
                        "causal": False, "clock": "guest_monotonic_us"}
        item["transitions"].append(gap("guest_frame_to_host_present",
                                        "no_exported_guest_frame_to_host_generation_bridge"))
        frame_results.append(item)
    return {
        "schemaVersion": 1, "runID": run_id,
        "hostInputs": inputs, "guestHandlers": handlers, "guestFrames": frame_results,
        "issues": issues,
        "evidenceCounts": {"hostIdentities": len(host), "guestTouchIdentities": len(touches),
                           "guestFrameIdentities": len(frame_results),
                           "ignoredLegacyInteractions": len(records(report, "interactions"))},
        "endToEnd": {"status": "unobserved_transition", "semanticAcknowledgement": "unobserved",
                     "reason": "existing_events_do_not_join_host_input_client_ack_and_frame"},
        "limitations": [
            "observed_delay means an elapsed span, not a budget violation or diagnosed stall",
            "missing_transition requires explicit disposition; silence/expiry is unobserved",
            "identities are scoped to this declared run and producer; host and Phoc IDs never join",
            "temporalOnly frames and app IDs do not acknowledge input or launch instances",
            "bounded rings and lossy UART do not prove trace completeness",
            "thread CPU accounting is not runnable time; wall minus CPU is not blocking time",
            "no scheduler, Gecko, IPC or fence attribution can be inferred from these records",
            "legacy interactions, precomputed guestFrameStages and aggregate percentiles are not causal evidence",
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", required=True, help="one run/boot; never combine independent runs")
    parser.add_argument("--metrics", type=Path, help="one VM performance JSON snapshot")
    parser.add_argument("--uart", type=Path, help="saved raw UART from the same run")
    args = parser.parse_args()
    if not args.metrics and not args.uart:
        parser.error("at least one of --metrics or --uart is required")
    provenance, report, guest, issues = [], {}, [], []
    try:
        for kind, path in (("metrics", args.metrics), ("uart", args.uart)):
            if path is None:
                continue
            raw = path.read_bytes()
            provenance.append({"kind": kind, "path": str(path.resolve()), "bytes": len(raw),
                               "sha256": hashlib.sha256(raw).hexdigest()})
            if kind == "metrics":
                report = json.loads(raw)
            else:
                guest, issues = uart_events(raw)
        result = analyze(report, guest, args.run_id)
        result["sources"] = provenance
        result["issues"].extend(issues)
    except (OSError, ValueError, UnicodeError) as error:
        parser.error(str(error))
    print(json.dumps(result, indent=2, allow_nan=False))


if __name__ == "__main__":
    main()
