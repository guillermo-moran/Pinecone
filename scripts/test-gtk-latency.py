#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("probe", Path(__file__).with_name("analyze-gtk-latency.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


def line(event, when, seq=0, length=0):
    return f"PINECONE_GTK pid=7 mono_us={when} event={event} seq={seq} length={length}\n"


class TimingTests(unittest.TestCase):
    def test_exec_discards_preexec_constructor(self):
        text = line("constructor", 10) + line("exec", 20) + line("constructor", 1020)
        self.assertEqual(probe.summarize(text)["processes"]["7"]["startup"]["execToConstructorMs"], 1)

    def test_coalesced_insertions_are_not_invented_frames(self):
        text = line("insert_begin", 100, 1, 1) + line("insert_end", 200, 1)
        text += line("insert_begin", 300, 2, 1) + line("insert_end", 400, 2) + line("after_paint", 1300, 2)
        samples = probe.summarize(text)["processes"]["7"]["insertions"]
        self.assertNotIn("insertToAfterPaintMs", samples[0])
        self.assertEqual(samples[1]["insertToAfterPaintMs"], 1)

    def test_missing_stages_are_not_zero(self):
        self.assertEqual(probe.summarize(line("exec", 100))["processes"]["7"]["startup"], {})

    def test_paint_phases_separate_queueing_from_frame_work(self):
        text = line("insert_begin", 100, 1, 1) + line("insert_end", 200, 1)
        text += line("before_paint", 500, 1) + line("after_paint", 2500, 1)
        sample = probe.summarize(text)["processes"]["7"]["insertions"][0]
        self.assertEqual(sample["insertToBeforePaintMs"], 0.4)
        self.assertEqual(sample["paintCycleMs"], 2)

    def test_bad_clock_and_duplicate_identity_rejected(self):
        for text in (line("exec", 0), line("exec", 100) + line("constructor", 99),
                     line("insert_begin", 10, 1) + line("insert_begin", 11, 1)):
            with self.assertRaises(ValueError):
                probe.summarize(text)


def frame(frame_id=12, sequence=1):
    stages = {name: dict(calls=0, wallNs=0, threadNs=0) for name in probe.FRAME_STAGES}
    stages["frame"] = dict(calls=1, wallNs=10000000, threadNs=4000000)
    stages["paint"] = dict(calls=1, wallNs=8000000, threadNs=3000000)
    stages["cairo_draw"] = dict(calls=2, wallNs=6000000, threadNs=2000000)
    return dict(version=1, pid=7, frame=frame_id, seqBegin=sequence, seqEnd=sequence,
                beginNs=1000000, endNs=11000000, valid=1, stages=stages)


def frame_line(record):
    return probe.FRAME_PREFIX + json.dumps(record) + "\n"


class FrameTests(unittest.TestCase):
    def parse(self, record):
        return probe.summarize(frame_line(record))["processes"]["7"]["frames"][0]

    def test_inclusive_stages_and_absent_stages(self):
        sample = self.parse(frame())
        self.assertEqual(sample["stages"]["frame"]["wallMs"], 10)
        self.assertEqual(sample["stages"]["paint"]["wallMs"], 8)
        self.assertEqual(sample["stages"]["cairo_draw"]["guestThreadMs"], 2)
        self.assertNotIn("layout", sample["stages"])
        self.assertNotIn("waitMs", sample)

    def test_changed_sequence_is_not_paired(self):
        record = frame()
        record["seqEnd"] = 2
        self.assertTrue(self.parse(record)["insertionChangedDuringFrame"])

    def test_repeated_sequence_distinct_frames(self):
        first, second = frame(), frame(13)
        second.update(beginNs=12000000, endNs=22000000)
        result = probe.summarize(frame_line(first) + frame_line(second))
        self.assertEqual(len(result["processes"]["7"]["frames"]), 2)
        self.assertEqual(result["processes"]["7"]["insertions"], [])

    def test_invalid_trace_excludes_timings(self):
        record = frame()
        record["valid"] = 0
        self.assertEqual(self.parse(record), {"frame": 12, "valid": False})

    def test_malformed_truncated_duplicate_and_bad_numbers(self):
        for text in (frame_line(frame())[:-4], frame_line(frame()) * 2,
                     frame_line(frame()).replace('"version": 1', '"version": 1, "version": 1')):
            with self.assertRaises(ValueError):
                probe.summarize(text)
        for field, value in (("beginNs", 0), ("endNs", 0), ("version", 2), ("pid", True)):
            record = frame()
            record[field] = value
            with self.assertRaises(ValueError):
                self.parse(record)

    def test_stage_validation(self):
        for mutation in (lambda s: s.pop("layout"),
                         lambda s: s["frame"].update(wallNs=1),
                         lambda s: s["layout"].update(wallNs=1),
                         lambda s: s["paint"].update(wallNs=11000000),
                         lambda s: s["paint"].update(threadNs=-1)):
            record = frame()
            mutation(record["stages"])
            with self.assertRaises(ValueError):
                self.parse(record)

    def test_mixed_old_and_new_records(self):
        text = line("insert_begin", 100, 1, 1) + line("insert_end", 200, 1)
        text += frame_line(frame())
        process = probe.summarize(text)["processes"]["7"]
        self.assertEqual(process["insertions"][0]["insertHandlerMs"], 0.1)
        self.assertEqual(len(process["frames"]), 1)


if __name__ == "__main__":
    unittest.main()
