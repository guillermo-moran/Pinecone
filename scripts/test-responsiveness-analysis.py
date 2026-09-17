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


if __name__ == "__main__":
    unittest.main()
