#!/usr/bin/env python3
"""Synthetic offline regressions; no VM, compiler, browser or network used."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name("phase7-interaction-trace.py")
SPEC = importlib.util.spec_from_file_location("interaction_trace", SCRIPT)
TRACE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TRACE)


def host(**changes):
    return {"identity": {"epoch": 1, "sequence": 1}, "phase": "down",
            "captureNanoseconds": 1_000_000, "queuedNanoseconds": 2_000_000,
            "injectedNanoseconds": 5_000_000, "disposition": "injectedUncorrelated", **changes}


def touch(**changes):
    return {"version": 2, "event": "touch", "epoch": 1, "inputSequence": 1,
            "guestUs": 100, "handlerEndUs": 110, "handlerCPUUs": 3,
            "touchID": 0, "phase": "down", "eventTimeMsec": 0xffffffff,
            "association": "none", **changes}


def frame(**changes):
    return {"version": 2, "event": "present", "epoch": 1, "frameID": 7,
            "outputID": 22, "sequence": 0, "renderUs": 200, "submitUs": 300,
            "commitUs": 400, "guestUs": 600, "renderCPUUs": 10,
            "submitCPUUs": 20, "commitCPUUs": 25, "inputSequence": 1,
            "inputUs": 100, "association": "temporalOnly", **changes}


def guest_report(*entries):
    return TRACE.analyze({"guestGraphics": list(entries)})


class AttributionTests(unittest.TestCase):
    def test_empty_trace_is_unknown_not_failure(self):
        result = TRACE.analyze({})
        self.assertEqual(result["endToEnd"]["status"], "unobserved_transition")
        self.assertEqual(result["hostInputs"], [])

    def test_host_durations_and_no_guest_clock_subtraction(self):
        result = TRACE.analyze({"inputAttribution": [host()], "guestGraphics": [touch()]})
        transitions = result["hostInputs"][0]["transitions"]
        self.assertEqual([x.get("elapsedMs") for x in transitions], [1, 3, None])
        self.assertEqual(transitions[2]["status"], "unobserved_transition")

    def test_expired_input_retains_observed_injection_not_failure(self):
        result = TRACE.analyze({"inputAttribution": [host(disposition="expiredUncorrelated")]})
        self.assertEqual(result["hostInputs"][0]["transitions"][1]["elapsedMs"], 3)
        self.assertEqual(result["endToEnd"]["semanticAcknowledgement"], "unobserved")

    def test_expiry_reset_and_pending_without_endpoint_are_unobserved(self):
        for disposition in ("queued", "expiredUncorrelated", "reset", "sequenceWrap"):
            with self.subTest(disposition=disposition):
                sample = host(disposition=disposition)
                del sample["injectedNanoseconds"]
                transition = TRACE.analyze({"inputAttribution": [sample]})["hostInputs"][0]["transitions"][1]
                self.assertEqual(transition["status"], "unobserved_transition")

    def test_explicit_input_dispositions_are_missing_only_for_that_event(self):
        for disposition in ("rejected", "coalesced", "droppedMotion"):
            sample = host(disposition=disposition, injectedNanoseconds=None)
            result = TRACE.analyze({"inputAttribution": [sample]})
            self.assertEqual(result["hostInputs"][0]["transitions"][1]["status"], "missing_transition")
            self.assertEqual(result["endToEnd"]["status"], "unobserved_transition")

    def test_rejection_with_injection_is_invalid(self):
        result = TRACE.analyze({"inputAttribution": [host(disposition="rejected")]})
        self.assertEqual(result["hostInputs"][0]["transitions"][1]["status"], "invalid_evidence")

    def test_unknown_disposition_is_invalid_not_a_success(self):
        for disposition in ("acknowledged", None, [], {}):
            result = TRACE.analyze({"inputAttribution": [host(disposition=disposition)]})
            self.assertEqual(result["hostInputs"][0]["transitions"][1]["status"], "invalid_evidence")

    def test_host_timestamp_validation(self):
        for value in (True, -1, "3", 1.5, float("nan"), 1 << 64, 1):
            result = TRACE.analyze({"inputAttribution": [host(injectedNanoseconds=value)]})
            self.assertEqual(result["hostInputs"][0]["transitions"][1]["status"], "invalid_evidence")

    def test_full_width_uint64_subtraction_is_exact(self):
        base = (1 << 64) - 100
        result = TRACE.analyze({"inputAttribution": [host(captureNanoseconds=base,
            queuedNanoseconds=base + 1, injectedNanoseconds=base + 2)]})
        self.assertEqual(result["hostInputs"][0]["transitions"][1]["elapsedMs"], .000001)

    def test_guest_handler_cpu_is_separate_accounting(self):
        item = guest_report(touch())["guestHandlers"][0]["transitions"][0]
        self.assertEqual(item["elapsedMs"], .01)
        self.assertEqual(item["threadCpuMs"], .003)
        self.assertNotIn("waitMs", item)

    def test_frame_stage_identity_and_cpu(self):
        item = guest_report(frame())["guestFrames"][0]
        self.assertEqual(item["identity"], {"epoch": 1, "frameID": 7, "outputID": 22, "sequence": 0})
        self.assertEqual([x.get("elapsedMs") for x in item["transitions"]], [.1, .1, .2, None])
        self.assertEqual(item["transitions"][0]["threadCpuMs"], .01)
        self.assertEqual(item["transitions"][1]["threadCpuMs"], .005)

    def test_temporal_frame_never_acknowledges_input(self):
        item = guest_report(frame(), touch())["guestFrames"][0]
        self.assertEqual(item["inputAssociation"], "temporalOnly")
        self.assertFalse(item["temporalContext"]["causal"])
        self.assertEqual(item["inputAcknowledgement"], "unobserved")

    def test_unrelated_frames_do_not_match(self):
        for changes in ({"epoch": 2}, {"inputSequence": 9}, {"inputUs": 101},
                        {"association": "causal"}, {"renderUs": 2_000_101,
                         "submitUs": 2_000_102, "commitUs": 2_000_103, "guestUs": 2_000_104}):
            with self.subTest(changes=changes):
                item = guest_report(touch(), frame(**changes))["guestFrames"][0]
                self.assertNotIn("temporalContext", item)

    def test_incomplete_handler_does_not_match_frame(self):
        item = guest_report(touch(handlerEndUs=None), frame())["guestFrames"][0]
        self.assertEqual(item["inputAssociation"], "unmatched")

    def test_identity_reuse_across_epochs_is_not_a_conflict(self):
        result = guest_report(touch(), touch(epoch=2), frame(), frame(epoch=2))
        self.assertEqual(len(result["guestFrames"]), 2)
        self.assertFalse(result["issues"])

    def test_duplicates_and_uart_order_do_not_inflate_counts(self):
        result = guest_report(frame(), touch(), copy.deepcopy(frame()), copy.deepcopy(touch()))
        self.assertEqual(len(result["guestFrames"]), 1)
        self.assertEqual(len(result["guestHandlers"]), 1)

    def test_same_commit_sequence_on_distinct_outputs_is_not_joined(self):
        result = guest_report(frame(), frame(frameID=8, outputID=23))
        self.assertEqual(len(result["guestFrames"]), 2)
        self.assertNotEqual(result["guestFrames"][0]["identity"], result["guestFrames"][1]["identity"])

    def test_conflicting_touch_is_excluded_not_used_for_association(self):
        result = guest_report(touch(), touch(handlerEndUs=120), frame())
        self.assertEqual(result["guestHandlers"], [])
        self.assertEqual(result["guestFrames"][0]["inputAssociation"], "unmatched")
        self.assertTrue(result["issues"])

    def test_conflicting_frame_output_or_disposition_is_excluded(self):
        for other in (frame(outputID=23), frame(event="dropped", reason="expired")):
            result = guest_report(frame(), other)
            self.assertEqual(result["guestFrames"], [])
            self.assertTrue(result["issues"])

    def test_conflicting_host_records_are_not_merged(self):
        result = TRACE.analyze({"inputAttribution": [host(), host(injectedNanoseconds=6_000_000)]})
        self.assertEqual(result["hostInputs"], [])
        self.assertTrue(result["issues"])

    def test_invalid_identities_and_versions_excluded(self):
        for changes in ({"epoch": 0}, {"epoch": True}, {"frameID": "7"}, {"version": 1},
                        {"version": 2.0}, {"outputID": 0}, {"sequence": 1 << 32}):
            result = guest_report(frame(**changes))
            self.assertEqual(result["guestFrames"], [])
            self.assertTrue(result["issues"])

    def test_reversed_frame_clock_is_invalid_not_negative_latency(self):
        item = guest_report(frame(commitUs=299))["guestFrames"][0]
        self.assertEqual(item["transitions"][0]["status"], "invalid_evidence")
        self.assertFalse(any("elapsedMs" in x for x in item["transitions"]))

    def test_missing_frame_endpoint_is_unobserved(self):
        sample = frame()
        del sample["submitUs"]
        item = guest_report(sample)["guestFrames"][0]
        self.assertEqual(item["transitions"][0]["status"], "unobserved_transition")
        self.assertEqual(item["transitions"][2]["elapsedMs"], .2)

    def test_cpu_clock_reversal_does_not_invalidate_wall_clock(self):
        item = guest_report(frame(submitCPUUs=5))["guestFrames"][0]["transitions"][0]
        self.assertEqual(item["elapsedMs"], .1)
        self.assertEqual(item["cpuEvidence"], "invalid")

    def test_trace_retirement_is_not_necessarily_presentation_failure(self):
        for reason in ("expired", "capacityEvicted", "sequenceReused", "outputDestroyed", "unknown"):
            item = guest_report(frame(event="dropped", reason=reason))["guestFrames"][0]
            self.assertEqual(item["transitions"][0]["status"], "unobserved_transition")

    def test_explicit_frame_failure_is_missing(self):
        for reason in ("aborted", "notPresented"):
            item = guest_report(frame(event="dropped", reason=reason))["guestFrames"][0]
            self.assertEqual(item["transitions"][0]["status"], "missing_transition")

    def test_legacy_and_aggregate_data_do_not_create_causality(self):
        result = TRACE.analyze({"interactions": [{"generation": 7, "totalMilliseconds": 12}],
                               "guestFrameStages": [{"inputAssociation": "causal"}],
                               "framePipeline": {"frameSampleCount": 127}})
        self.assertEqual(result["evidenceCounts"]["ignoredLegacyInteractions"], 1)
        self.assertEqual(result["guestFrames"], [])
        self.assertEqual(result["endToEnd"]["semanticAcknowledgement"], "unobserved")

    def test_uart_recovers_at_rs_and_rejects_partial_lines(self):
        encoded = b"\x1ePINECONE_TRACE " + json.dumps(touch()).encode()
        raw = b"unrelated log\npartial trace" + encoded + b"\r\n" + encoded
        entries, issues = TRACE.uart_events(raw)
        self.assertEqual(entries, [touch()])
        self.assertEqual(len(issues), 1)

    def test_uart_malformed_and_oversize_reported(self):
        entries, issues = TRACE.uart_events(b"PINECONE_TRACE nope\nPINECONE_TRACE " + b"x" * 2050 + b"\n")
        self.assertEqual(entries, [])
        self.assertEqual(len(issues), 2)

    def test_metrics_shape_rejected(self):
        for value in ([], {"guestGraphics": {}}, {"inputAttribution": [1]}):
            with self.assertRaises(ValueError):
                TRACE.analyze(value)

    def test_cli_provenance_and_read_only_input(self):
        with tempfile.TemporaryDirectory(prefix="phase7-interaction-trace-") as directory:
            path = Path(directory) / "metrics.json"
            raw = json.dumps({"inputAttribution": [host()]}).encode()
            path.write_bytes(raw)
            command = [sys.executable, str(SCRIPT), "--run-id", "synthetic", "--metrics", str(path)]
            completed = subprocess.run(command, capture_output=True, text=True, check=True)
            result = json.loads(completed.stdout)
            self.assertEqual(result["runID"], "synthetic")
            self.assertEqual(len(result["sources"][0]["sha256"]), 64)
            self.assertEqual(path.read_bytes(), raw)
            path.write_text("[]")
            completed = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("metrics must be", completed.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
