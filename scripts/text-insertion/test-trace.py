#!/usr/bin/env python3
"""Small host tests only. Optional source roots validate the real upstream patches."""
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


analyze = load("text_trace_analyze", HERE / "analyze.py").analyze
patcher = load("text_trace_patcher", HERE / "make-patch.py")

FIXTURE = r'''
#include "trace.h"
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
static int child(void) {
  PC_TEXT_SCOPE("child", 0);
  return 7;
}
static void *worker(void *arg) {
  PC_TEXT_SCOPE("foreign-thread", 1);
  return arg;
}
int main(int argc, char **argv) {
  (void)argv;
  if (argc > 1) {
    for (int i = 0; i < 257; i++) { PC_TEXT_SCOPE("edit", 1); }
    return 0;
  }
  { PC_TEXT_SCOPE("outside-edit", 0); }
  {
    errno = EDOM;
    PC_TEXT_SCOPE("edit", 1);
    assert(errno == EDOM);
    assert(child() == 7);
    int calls = 0;
    if (1) PC_TEXT_CALL("statement", calls++); else assert(0);
    assert(calls == 1);
    /* Macro transparency, not an editor/IME test. No text enters the probe API. */
    char value[64] = "hello";
    PC_TEXT_CALL("insert", strcat(value, " world"));
    assert(strcmp(value, "hello world") == 0);
    PC_TEXT_CALL("delete", value[5] = '\0');
    assert(strcmp(value, "hello") == 0);
    PC_TEXT_CALL("selection-replace", strcpy(value, "selected"));
    PC_TEXT_CALL("composition-commit", strcpy(value, "caf\xc3\xa9 e\xcc\x81 \xe6\x97\xa5"));
    assert(strcmp(value, "caf\xc3\xa9 e\xcc\x81 \xe6\x97\xa5") == 0);
    pthread_t thread;
    assert(pthread_create(&thread, NULL, worker, NULL) == 0);
    assert(pthread_join(thread, NULL) == 0);
    errno = EDOM;
  }
  assert(errno == EDOM);
  puts("same-result");
  return 0;
}
'''


class RuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="text-insertion-tests-")
        cls.root = Path(cls.temp.name)
        fixture = cls.root / "fixture.c"
        fixture.write_text(FIXTURE)
        for suffix, flags in [("normal", []), ("small", ["-DPC_TEXT_CAPACITY=3"])]:
            subprocess.run([os.environ.get("CC", "cc"), "-std=c11", "-Wall", "-Wextra",
                            "-Werror", "-Wshadow", "-O2", "-I", str(HERE), *flags,
                            str(HERE / "trace.c"), str(fixture), "-pthread",
                            "-o", str(cls.root / suffix)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def capture(self, enabled="1", binary="normal", args=()):
        env = dict(os.environ, PINECONE_TEXT_INSERTION_TRACE=enabled)
        return subprocess.run([str(self.root / binary), *args], env=env,
                              capture_output=True, text=True, check=True)

    def test_disabled_and_transparent_operations(self):
        baseline = self.capture("0")
        traced = self.capture()
        self.assertEqual(baseline.stdout, traced.stdout)
        self.assertEqual(baseline.stderr, "")
        self.assertEqual(self.capture("yes").stderr, "")
        self.assertNotIn("selected", traced.stderr)
        self.assertNotIn("caf", traced.stderr)

    def test_nesting_return_and_thread_filter(self):
        report = next(iter(analyze(self.capture().stderr).values()))
        self.assertEqual(report["edits"], 1)
        labels = report["labels"]
        self.assertNotIn("outside-edit", labels)
        self.assertNotIn("foreign-thread", labels)
        self.assertEqual(labels["child"]["calls"], 1)
        self.assertEqual(labels["edit"]["calls"], 1)
        self.assertGreaterEqual(labels["edit"]["median_wall_outside_traced_children_ms"], 0)

    def test_saturation_is_not_zero_latency(self):
        for result in [self.capture(binary="small"), self.capture(args=["limit"])]:
            with self.assertRaisesRegex(ValueError, "saturated"):
                analyze(result.stderr)

    def test_incomplete_duplicate_and_clock_rejection(self):
        text = self.capture().stderr
        variants = ["", text.rsplit("PCEDIT1 done", 1)[0], text + text,
                    text.replace("complete=1", "complete=0", 1),
                    re.sub(r"start=\d+", "start=0", text, count=1),
                    text.replace("parent=1", "parent=999", 1),
                    text.replace("edit=1", "edit=2", 1)]
        for bad in variants:
            with self.subTest(bad=bad[:80]), self.assertRaises(ValueError):
                analyze(bad)

    def test_shared_runtime_across_library_boundary(self):
        # Production packages must share a runtime, not have private counters.
        suffix = "dylib" if sys.platform == "darwin" else "so"
        kind = "-dynamiclib" if sys.platform == "darwin" else "-shared"
        lib = self.root / f"libtrace.{suffix}"
        cc = os.environ.get("CC", "cc")
        common = [cc, "-std=c11", "-Wall", "-Wextra", "-Werror", "-fPIC", "-I", str(HERE)]
        subprocess.run([*common, kind, str(HERE / "trace.c"), "-pthread", "-o", str(lib)], check=True)
        helper = self.root / "helper.c"
        helper.write_text('#include "trace.h"\nvoid helper(void) { PC_TEXT_SCOPE("library-child", 0); }\n')
        helper_lib = self.root / f"libhelper.{suffix}"
        subprocess.run([*common, kind, str(helper), str(lib), "-o", str(helper_lib)], check=True)
        main = self.root / "shared-main.c"
        main.write_text('#include "trace.h"\nvoid helper(void);\nint main(void) { '
                        'PC_TEXT_SCOPE("shared-root", 1); helper(); return 0; }\n')
        binary = self.root / "shared-main"
        subprocess.run([*common, str(main), str(helper_lib), str(lib),
                        f"-Wl,-rpath,{self.root}", "-o", str(binary)], check=True)
        result = self.capture(binary="shared-main")
        report = next(iter(analyze(result.stderr).values()))
        self.assertEqual(report["edits"], 1)
        self.assertEqual(set(report["labels"]), {"shared-root", "library-child"})


class AnalyzerTests(unittest.TestCase):
    SAMPLE = """PCEDIT1 summary pid=10 records=3 edits=1 dropped=0 limited=0
PCEDIT1 span pid=10 id=1 parent=0 edit=1 name=root start=100 end=1000100 cpu_start=10 cpu_end=800010 complete=1
PCEDIT1 span pid=10 id=2 parent=1 edit=1 name=child start=200 end=500200 cpu_start=20 cpu_end=400020 complete=1
PCEDIT1 span pid=10 id=3 parent=2 edit=1 name=grandchild start=300 end=100300 cpu_start=30 cpu_end=90030 complete=1
PCEDIT1 done pid=10
"""

    def test_only_direct_children_subtracted(self):
        report = analyze(self.SAMPLE)[10]["labels"]
        self.assertEqual(report["root"]["median_inclusive_wall_ms"], 1)
        self.assertEqual(report["root"]["median_wall_outside_traced_children_ms"], .5)
        self.assertEqual(report["child"]["median_wall_outside_traced_children_ms"], .4)
        self.assertEqual(report["root"]["median_guest_thread_cpu_ms"], .8)
        stages = analyze(self.SAMPLE)[10]["edit_roots"][0]["stages"]
        self.assertEqual([s["name"] for s in stages], ["root", "child", "grandchild"])
        self.assertEqual(stages[0]["wall_outside_traced_children_ms"], .5)

    def test_bad_nesting_and_counts(self):
        for old, new in [("records=3", "records=4"), ("edits=1", "edits=2"),
                         ("parent=2", "parent=1"), ("end=100300", "end=9999999"),
                         ("cpu_end=90030", "cpu_end=0"), ("id=3", "id=2")]:
            with self.subTest(old=old), self.assertRaises(ValueError):
                analyze(self.SAMPLE.replace(old, new))


class SourceTests(unittest.TestCase):
    def test_fail_closed_source_identity(self):
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            patcher.transform("file.c", "unverified", "0" * 64, [])

    def test_real_source_only_adds_scopes(self):
        roots = {"editor": os.environ.get("PC_TEXT_EDITOR_SOURCE"),
                 "sourceview": os.environ.get("PC_TEXT_SOURCEVIEW_SOURCE")}
        if not all(roots.values()):
            self.skipTest("set PC_TEXT_EDITOR_SOURCE and PC_TEXT_SOURCEVIEW_SOURCE")
        for component, root in roots.items():
            self.assertTrue(patcher.make_patch(component, Path(root)))
            for path, (digest, functions) in patcher.FILES[component].items():
                source = (Path(root) / path).read_text()
                result = patcher.transform(path, source, digest, functions)
                if path == "src/editor-document.c":
                    self.assertIn('PC_TEXT_SCOPE ("editor_document_insert_text", 1);\n'
                                  '  if (self->loading)', result)
                if path == "gtksourceview/gtksourcebuffer.c":
                    self.assertIn('PC_TEXT_SCOPE ("gtk_source_buffer_real_insert_text", 1);', result)
                # Exact inverse proves no production statement/condition was lost.
                result = result.replace('#include "pinecone-text-trace.h"\n', "")
                result = re.sub(r'^  PC_TEXT_SCOPE .*\n', "", result, flags=re.M)
                result = re.sub(r'PC_TEXT_CALL \("[^"]+", (.*)\);', r'\1;', result)
                self.assertEqual(result, source, path)
                with self.assertRaises(ValueError):
                    patcher.transform(path, source + "\n", digest, functions)


if __name__ == "__main__":
    unittest.main()
