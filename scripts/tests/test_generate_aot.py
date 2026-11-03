import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "generate-aot.py"
spec = importlib.util.spec_from_file_location("generate_aot", SCRIPT)
aot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(aot)


class AOTGeneratorTests(unittest.TestCase):
    def test_reserved_encodings_and_unsupported_semantics_are_rejected(self):
        for word in [0xffffffff, 0x91800000, 0x0bc00000, 0xf9400000,
                     0x52c00000, 0x32800000, 0x14000000, 0x94000001]:
            with self.subTest(word=hex(word)):
                with self.assertRaises(ValueError):
                    aot.translate(word, 0, 1)

    def test_branches_only_leave_at_terminal_boundary(self):
        with self.assertRaises(ValueError):
            aot.translate(0x14000002, 0, 2)
        with self.assertRaises(ValueError):
            aot.translate(0x17ffffff, 1, 2)
        self.assertIn("UINT64_C", aot.translate(0x17ffffff, 0, 1)[1])

    def test_content_dedup_and_reproducible_generation(self):
        records = [{"words": ["91000400", "14000001"]}, {"words": ["d503201f"]}]
        first = aot.generate(records)
        self.assertEqual(first, aot.generate([*reversed(records), records[0]]))
        self.assertEqual(first[1:], (2, 0))

    def test_unsupported_instruction_rejects_whole_block(self):
        text, compiled, rejected = aot.generate([{"words": ["91000400", "f9400000"]}])
        self.assertEqual((compiled, rejected), (0, 1))
        self.assertNotIn("static void ag_aot_block_", text)

    def test_corrupt_capture_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            capture = Path(directory) / "capture.jsonl"
            capture.write_text('{"words":["91000400"]}\n{"words":[')
            with self.assertRaisesRegex(ValueError, "line 2"):
                aot.read_records(capture)

    def test_instruction_and_block_limits(self):
        for words in [[], [0xd503201f] * 17, [-1], [0x100000000]]:
            with self.assertRaises(ValueError):
                aot.generate([{"words": words}])

    def test_prefixes_stop_before_unsupported_operations(self):
        manifest = []
        _, count, rejected = aot.generate([
            {"words": ["b1000400", "f9400000", "91000400"]},
            {"words": ["f9400000", "91000400"]},
        ], prefixes=True, manifest=manifest)
        self.assertEqual((count, rejected), (1, 1))
        self.assertEqual(manifest, [{"words": ["b1000400"]}])

    def test_sample_weights_rank_execution_candidates(self):
        manifest = []
        aot.generate([{"words": ["91000400"], "weight": 1}] * 10 +
                     [{"words": ["d503201f"], "weight": 100}], max_blocks=1, manifest=manifest)
        self.assertEqual(manifest, [{"words": ["d503201f"]}])
        for weight in [-1, 1.5, True]:
            with self.assertRaises(ValueError):
                aot.generate([{"words": ["d503201f"], "weight": weight}])

    def test_span_eligibility_requires_independent_pure_family_gate(self):
        for word in (0xf9400000, 0xf9000000, 0xd53bd040, 0xd5033f9f, 0xd4000001, 0x94000001):
            with self.subTest(word=hex(word)):
                self.assertFalse(aot.pure_span_instruction(word))
        for record in differential_corpus():
            for word in record["words"]:
                self.assertTrue(aot.pure_span_instruction(int(word, 16)))
        # Simulate a future translator extension accepting a memory operation.
        # It must not silently gain the copied-span execution contract.
        with patch.object(aot, "translate", return_value=("/* future translation */", None)):
            text, compiled, rejected = aot.generate([{"words": ["f9400000"]}])
        self.assertEqual((compiled, rejected), (1, 0))
        self.assertNotIn("static void ag_aot_block_0_span", text)
        self.assertRegex(text, r"ag_aot_block_0, UINT64_C\([0-9]+\), NULL")


def differential_corpus():
    """Exercise every accepted move-wide width/op/halfword and arithmetic
    immediate width/op/shift, including ZR, SP and operand aliases in native C."""
    records = []
    for sf in range(2):
        for opcode in (0, 2, 3):
            for half in range(2 if not sf else 4):
                for rd in (0, 1, 30, 31):
                    word = 0x12800000 | sf << 31 | opcode << 29 | half << 21 | 0xabc5 << 5 | rd
                    records.append({"words": [f"{word:08x}"]})
        for sub in range(2):
          for flags in range(2):
            for shift in range(2):
                for imm in (0, 1, 0xfff):
                    for rn in (0, 1, 31):
                        for rd in (0, 1, 31):
                            word = 0x11000000 | sf << 31 | sub << 30 | flags << 29 | shift << 22 | imm << 10 | rn << 5 | rd
                            records.append({"words": [f"{word:08x}"]})
        bits = 64 if sf else 32
        for sub in range(2):
          for flags in range(2):
            for shift in range(3):
              for amount in (0, 1, bits - 1):
                for rd, rn, rm in [(0, 1, 2), (0, 0, 0), (31, 31, 31), (1, 31, 1)]:
                    word = 0x0b000000 | sf << 31 | sub << 30 | flags << 29 | shift << 22 | rm << 16 | amount << 10 | rn << 5 | rd
                    records.append({"words": [f"{word:08x}"]})
            for extension in range(8):
              for amount in (0, 4):
                for rd, rn, rm in [(0, 1, 2), (31, 31, 31), (1, 31, 1)]:
                    word = 0x0b200000 | sf << 31 | sub << 30 | flags << 29 | extension << 13 | rm << 16 | amount << 10 | rn << 5 | rd
                    records.append({"words": [f"{word:08x}"]})
        for opcode in range(4):
          for invert in range(2):
            for shift in range(4):
              for amount in (0, 1, bits - 1):
                for rd, rn, rm in [(0, 1, 2), (0, 0, 0), (31, 31, 31), (1, 31, 1)]:
                    word = 0x0a000000 | sf << 31 | opcode << 29 | invert << 21 | shift << 22 | rm << 16 | amount << 10 | rn << 5 | rd
                    records.append({"words": [f"{word:08x}"]})
          for n in range(2):
            for immr in (0, 1, 15, 31, 32, 63):
              for imms in (0, 1, 15, 30, 31, 32, 47, 62, 63):
                word = 0x12000000 | sf << 31 | opcode << 29 | n << 22 | immr << 16 | imms << 10 | 1 << 5 | 31
                try:
                    aot.translate(word, 0, 1)
                except ValueError:
                    continue
                records.append({"words": [f"{word:08x}"]})
        for invert in range(2):
          for increment in range(2):
            for cond in range(16):
              for rd, rn, rm in [(0, 1, 2), (0, 0, 0), (31, 31, 31)]:
                word = 0x1a800000 | sf << 31 | invert << 30 | increment << 10 | cond << 12 | rm << 16 | rn << 5 | rd
                records.append({"words": [f"{word:08x}"]})
        for opcode in range(3):
          for immr in (0, 1, 15, 31, 32, 63):
            for imms in (0, 1, 15, 30, 31, 32, 47, 63):
              if immr < bits and imms < bits:
                for rd, rn in [(0, 1), (0, 0), (31, 31)]:
                    word = 0x13000000 | sf << 31 | opcode << 29 | sf << 22 | immr << 16 | imms << 10 | rn << 5 | rd
                    records.append({"words": [f"{word:08x}"]})
        for amount in (0, 1, bits - 1):
          for rd, rn, rm in [(0, 1, 2), (0, 0, 0), (31, 31, 31)]:
            word = 0x13800000 | sf << 31 | sf << 22 | rm << 16 | amount << 10 | rn << 5 | rd
            records.append({"words": [f"{word:08x}"]})
        for nonzero in range(2):
            for offset in (-4, 4, 1048572):
                for reg in (0, 31):
                    word = 0x34000000 | sf << 31 | nonzero << 24 | ((offset // 4) & 0x7ffff) << 5 | reg
                    records.append({"words": [f"{word:08x}"]})
    for page in range(2):
      for offset in (0, 1, -1, 1048575, -1048576):
        encoded = offset & 0x1fffff
        word = 0x10000000 | page << 31 | (encoded & 3) << 29 | (encoded >> 2) << 5
        records.append({"words": [f"{word:08x}"]})
    for cond in range(16):
        for offset in (-4, 4):
            word = 0x54000000 | ((offset // 4) & 0x7ffff) << 5 | cond
            records.append({"words": [f"{word:08x}"]})
            if offset == 4:
                records.append({"words": ["f100001f", f"{word:08x}"]})
    for bit in (0, 1, 31, 32, 63):
      for nonzero in range(2):
        for offset in (-4, 4):
          for rd in (0, 31):
            word = 0x36000000 | (bit >> 5) << 31 | nonzero << 24 | (bit & 31) << 19 | ((offset // 4) & 0x3fff) << 5 | rd
            records.append({"words": [f"{word:08x}"]})
    return records


if __name__ == "__main__":
    import sys
    if len(sys.argv) == 3 and sys.argv[1] == "--write-corpus":
        Path(sys.argv[2]).write_text(json.dumps(differential_corpus()) + "\n")
    else:
        unittest.main()
