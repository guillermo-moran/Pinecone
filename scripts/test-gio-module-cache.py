#!/usr/bin/env python3
"""Small native test of GIO's real eager/lazy module paths, not a benchmark."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
import unittest


SOURCE = Path(__file__).with_name("gio-module-cache-regression.c")


class GioCacheTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="gio-module-cache-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.work = Path(cls.temp.name)
        cls.modules = cls.work / "modules"
        cls.modules.mkdir()
        cls.log = cls.work / "load.log"
        cls.env = {**os.environ, "PINECONE_TEST_MODULE_LOG": str(cls.log)}
        flags = shlex.split(subprocess.check_output(
            ["pkg-config", "--cflags", "--libs", "gio-2.0"], text=True))
        cc = shlex.split(os.environ.get("CC", "cc"))
        common = [*cc, "-Wall", "-Wextra", "-Werror", str(SOURCE), *flags]
        subprocess.run([*common, "-fPIC", "-shared", "-DBUILD_MODULE",
                        "-o", str(cls.modules / "libfixture.so")], check=True)
        cls.client = cls.work / "scan"
        subprocess.run([*common, "-o", str(cls.client)], check=True)

    def setUp(self):
        self.log.unlink(missing_ok=True)
        (self.modules / "giomodule.cache").unlink(missing_ok=True)

    def scan(self, cached):
        subprocess.run([str(self.client), str(self.modules), cached],
                       env=self.env, check=True)

    def test_no_cache_loads_during_scan(self):
        self.scan("uncached")

    def test_generated_cache_defers_load_but_preserves_extension(self):
        subprocess.run(["gio-querymodules", str(self.modules)], env=self.env, check=True)
        self.assertEqual((self.modules / "giomodule.cache").read_text(),
                         "libfixture.so: pinecone-cache-regression\n")
        self.assertFalse(self.log.exists(), "query must not initialize the module")
        self.scan("cached")

    def test_cache_without_module_entry_retains_eager_fallback(self):
        (self.modules / "giomodule.cache").write_text("libother.so: other-point\n")
        self.scan("uncached")

    def test_changed_module_retains_eager_fallback(self):
        subprocess.run(["gio-querymodules", str(self.modules)], env=self.env, check=True)
        cache = self.modules / "giomodule.cache"
        cache_time = int(max(cache.stat().st_ctime, cache.stat().st_mtime))
        # GIO compares whole seconds. Cross that boundary before changing ctime.
        time.sleep(max(0, cache_time + 1.1 - time.time()))
        module = self.modules / "libfixture.so"
        module.chmod(0o755)
        self.assertGreater(int(module.stat().st_ctime), cache_time)
        self.scan("uncached")

    def test_empty_directory_removes_stale_cache(self):
        with tempfile.TemporaryDirectory(dir=self.work) as directory:
            cache = Path(directory) / "giomodule.cache"
            cache.write_text("libremoved.so: removed-point\n")
            subprocess.run(["gio-querymodules", directory], env=self.env, check=True)
            self.assertFalse(cache.exists())


if __name__ == "__main__":
    unittest.main()
