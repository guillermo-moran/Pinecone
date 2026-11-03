import importlib.util
from pathlib import Path
import unittest

script = Path(__file__).resolve().parents[1] / "select-aot-profile.py"
spec = importlib.util.spec_from_file_location("select_aot_profile", script)
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)


class SelectAOTProfileTests(unittest.TestCase):
    def test_merges_full_code_across_addresses_and_vcpus_using_error_bound(self):
        reports = [{"primaryHotPCs": [{"pc": "0x1000", "samples": 100,
            "sampleError": 90, "instructions": ["0x91000400", "0x14000001"]}],
            "secondaryHotPCs": [{"pc": "0x2000", "samples": "20", "sampleError": "2",
                "instructions": "91000400 14000001"}]}]
        result = profile.select(reports)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["weight"], 28)
        self.assertEqual(result[0]["sampledInstructionWeight"], 56)
        self.assertEqual(result[0]["pcs"], ["0x1000", "0x2000"])

    def test_rejects_old_truncated_profile_as_aot_candidate(self):
        self.assertEqual(profile.select([{"primaryHotPCs": [{"pc": "0x1000",
            "samples": 100, "instructions": ["0x91000400"]}]}]), [])

    def test_rejects_invalid_error(self):
        with self.assertRaises(ValueError):
            profile.select([{"primaryHotPCs": [{"pc": "0x1000", "samples": 1,
                "sampleError": 2, "instructions": ["0x91000400"]}]}])


if __name__ == "__main__":
    unittest.main()
