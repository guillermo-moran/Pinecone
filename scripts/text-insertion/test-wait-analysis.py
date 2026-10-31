#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("wait_analysis", Path(__file__).with_name("analyze-wait.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

CAPTURE = """PCWAIT1 summary pid=7 records=1 dropped=0
PCWAIT1 call pid=7 id=2 detail=Inhibit service=org.example.Test arg=123 result=1
PCWAIT1 done pid=7
PCEDIT1 summary pid=7 records=2 edits=1 dropped=0 limited=0
PCEDIT1 span pid=7 id=1 parent=0 edit=1 name=root start=100 end=300 cpu_start=10 cpu_end=30 complete=1
PCEDIT1 span pid=7 id=2 parent=1 edit=1 name=g_dbus_proxy_call_sync start=150 end=250 cpu_start=15 cpu_end=25 complete=1
PCEDIT1 done pid=7
"""


class WaitAnalysisTests(unittest.TestCase):
    def test_join(self):
        result = module.analyze_wait(CAPTURE)
        stages = result[7]["edit_roots"][0]["stages"]
        self.assertNotIn("call", stages[0])
        self.assertEqual(stages[1]["call"]["detail"], "Inhibit")
        self.assertEqual(stages[1]["parent"], 1)

    def test_reject_incomplete_or_saturated(self):
        for capture in (CAPTURE.replace("PCWAIT1 done pid=7\n", ""),
                        CAPTURE.replace("records=1 dropped=0", "records=1 dropped=1"),
                        CAPTURE.replace("records=1 dropped=0", "records=2 dropped=0")):
            with self.subTest(capture=capture), self.assertRaises(ValueError):
                module.analyze_wait(capture)

    def test_reject_unmatched(self):
        for capture in (CAPTURE.replace("call pid=7 id=2", "call pid=7 id=8"),
                        "\n".join(l for l in CAPTURE.splitlines() if not l.startswith("PCWAIT1"))):
            with self.subTest(capture=capture), self.assertRaises(ValueError):
                module.analyze_wait(capture)

    def test_reject_duplicate(self):
        call = CAPTURE.splitlines()[1]
        for capture in (CAPTURE.replace(call, call + "\n" + call),
                        CAPTURE.replace("arg=123", "arg=123 arg=456"),
                        CAPTURE + call):
            with self.subTest(capture=capture), self.assertRaises(ValueError):
                module.analyze_wait(capture)

    def test_checks_existing_edit_invariants(self):
        with self.assertRaises(ValueError):
            module.analyze_wait(CAPTURE.replace("parent=1", "parent=9"))

    def test_each_hook_requires_metadata(self):
        capture = "\n".join(l for l in CAPTURE.splitlines() if not l.startswith("PCWAIT1 call"))
        with self.assertRaises(ValueError):
            module.analyze_wait(capture.replace("records=1 dropped=0", "records=0 dropped=0"))
        with self.assertRaises(ValueError):
            module.analyze_wait(CAPTURE.replace("name=g_dbus_proxy_call_sync", "name=unrelated"))


if __name__ == "__main__":
    unittest.main()
