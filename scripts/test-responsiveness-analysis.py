#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest
import sys

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location(
    "analysis", Path(__file__).with_name("analyze-pinecone-responsiveness.py"))
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)


def checkpoint(pid=1, total=1, creates=1):
    return (f"pinecone-pixman-shm: pid={pid} total={total} creates={creates} initial_bytes=16 "
            "updates=0 update_bytes=0 empty_updates=0 direct_draws=0 invalid=0 "
            "budget_rejects=0 alloc_failures=0 update_rejects=0 releases=0\n")


class ResponsivenessAnalysisTests(unittest.TestCase):
    def test_empty_and_invalid_distributions(self):
        self.assertEqual(analysis.distribution([-1, float("nan")]), {"count": 0})
        self.assertEqual(analysis.distribution([3, 1, 2])["p95Ms"], 3)

    def test_guest_clock_deduplication_and_invalid_order(self):
        frame = {"event": "present", "inputUs": 1000, "renderUs": 3000,
                 "submitUs": 4000, "commitUs": 5000, "guestUs": 6000}
        result = analysis.summarize({"guestGraphics": [frame, frame,
            {**frame, "renderUs": 500, "submitUs": 400}]})
        self.assertEqual(result["guest"]["inputToRender"],
                         {"count": 1, "p50Ms": 2, "p95Ms": 2, "maxMs": 2})
        self.assertEqual(result["guest"]["renderToSubmit"]["count"], 2)

    def test_mapping_boundaries_and_file_offsets(self):
        uart = "PINECONE_MAP:94:phosh\r\n1000-2000 r-xp 00004000 00:01 42 /lib/test.so\r\n"
        result = analysis.summarize({"hotPCs": [{"pc": "0x1234"}, {"pc": "0x2000"}]}, uart)
        self.assertEqual(result["hotspots"][0]["candidates"][0]["fileOffset"], "0x4234")
        self.assertEqual(result["hotspots"][1]["candidates"], [])

    def test_checkpoints_not_summed(self):
        result = analysis.snapshot_counters(checkpoint() + checkpoint(total=2) + checkpoint(pid=2))
        self.assertEqual(result[1]["creates"], 1)
        self.assertEqual(result[1]["total"], 2)
        self.assertEqual(len(result), 2)

    def test_resets_and_truncation_rejected(self):
        with self.assertRaises(ValueError):
            analysis.snapshot_counters(checkpoint(total=2) + checkpoint())
        with self.assertRaises(ValueError):
            analysis.snapshot_counters(checkpoint(creates=2) + checkpoint(total=2))
        with self.assertRaises(ValueError):
            analysis.snapshot_counters(checkpoint().replace(" releases=0", ""))

    def test_input_clock_and_phase_separation(self):
        result = analysis.input_admission({"inputAttribution": [
            {"phase": "down", "captureNanoseconds": 1000000, "queuedNanoseconds": 2000000,
             "injectedNanoseconds": 5000000, "disposition": "expiredUncorrelated"},
            {"phase": "up", "queuedNanoseconds": 7000000, "disposition": "queued"},
            {"phase": "move", "captureNanoseconds": 10000000, "queuedNanoseconds": 100,
             "injectedNanoseconds": 99, "disposition": "coalesced"}]})
        self.assertEqual(result["hostPhases"]["down"]["captureToQueueMs"]["p50Ms"], 1)
        self.assertEqual(result["hostPhases"]["down"]["queueToInjectionMs"]["p50Ms"], 3)
        self.assertEqual(result["hostPhases"]["up"]["queueToInjectionMs"]["count"], 0)
        self.assertEqual(result["hostPhases"]["move"]["queueToInjectionMs"]["count"], 0)

    def test_guest_identity_duplicates_and_conflicts(self):
        event = {"event": "touch", "version": 2, "epoch": 2**63, "inputSequence": 1,
                 "phase": "down", "guestUs": 12}
        self.assertEqual(analysis.input_admission({"guestGraphics": [event, event]})["guestPhases"], {"down": 1})
        result = analysis.input_admission({"guestGraphics": [event, {**event, "guestUs": 13}]})
        self.assertEqual(result["guestPhases"], {})
        self.assertEqual(result["conflictingGuestIdentities"], 1)

    def test_validated_guest_stages_keep_wall_and_cpu_separate(self):
        report = {"guestFrameStages": [
            {"renderToSubmitMilliseconds": 100, "renderToSubmitCPUMilliseconds": 12},
            {"renderToSubmitMilliseconds": 50, "renderToSubmitCPUMilliseconds": None}]}
        stages = analysis.summarize(report)["validatedGuestFrameStages"]
        self.assertEqual(stages["renderToSubmitMilliseconds"]["count"], 2)
        self.assertEqual(stages["renderToSubmitCPUMilliseconds"]["p95Ms"], 12)
        self.assertEqual(stages["submitToCommitMilliseconds"]["count"], 0)


if __name__ == "__main__":
    unittest.main()
