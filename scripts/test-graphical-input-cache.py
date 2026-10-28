#!/usr/bin/env python3
"""Exercise cache generation without executing a foreign guest binary."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parent / "generate-aarch64-rootfs-caches.sh"


class InputCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="input-cache-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.root = self.work / "root"
        self.bin = self.work / "bin"
        self.bin.mkdir()
        for tool in ("fc-cache", "gdk-pixbuf-query-loaders", "gtk-query-immodules-3.0"):
            self.write(self.root / "usr/bin" / tool, "#!/bin/sh\nexit 0\n")
        self.write(self.root / "usr/lib/libgtk-3.so.0", "fixture GTK library\n")
        self.write(self.bin / "uname", "#!/bin/sh\necho Linux\n")
        self.write(self.bin / "id", "#!/bin/sh\necho 0\n")
        self.write(self.bin / "chroot", '''#!/bin/sh
case "$2" in
  */ld-musl-aarch64.so.1)
    [ "$3" = --list ] || exit 98
    [ "${FAIL_LINKER:-0}" = 0 ] || { echo 'missing runtime symbol' >&2; exit 9; }
    printf '%s\\n' "$4" >> "$LOADER_LOG"
    ;;
  */fc-cache) exit 0 ;;
  */gdk-pixbuf-query-loaders) echo pixbuf ;;
  */gtk-query-immodules-3.0)
    [ "${FAIL_QUERY:-0}" = 0 ] || exit 7
    [ "${OMIT_WAYLAND:-0}" = 0 ] || exit 0
    printf '%s\n' '\"/usr/lib/gtk-3.0/3.0.0/immodules/im-wayland.so\"' '\"wayland\" \"Wayland\" \"gtk30\" \"/usr/share/locale\" \"\"'
    ;;
  *) exit 99 ;;
esac
''')
        self.env = {**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"]}

    def write(self, path, contents):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)
        path.chmod(0o755)

    def run_cache(self, **env):
        return subprocess.run(["bash", str(SCRIPT), str(self.root)],
                              env={**self.env, **env}, capture_output=True, text=True)

    def test_generates_wayland_registry_in_guest_paths(self):
        result = self.run_cache()
        self.assertEqual(result.returncode, 0, result.stderr)
        cache = (self.root / "usr/lib/gtk-3.0/3.0.0/immodules.cache").read_text()
        self.assertIn('"wayland" ', cache)
        self.assertNotIn(str(self.root), cache)

    def test_missing_query_tool_fails_build(self):
        (self.root / "usr/bin/gtk-query-immodules-3.0").unlink()
        self.assertNotEqual(self.run_cache().returncode, 0)

    def test_non_gtk_profile_does_not_require_input_modules(self):
        (self.root / "usr/bin/gtk-query-immodules-3.0").unlink()
        (self.root / "usr/lib/libgtk-3.so.0").unlink()
        result = self.run_cache()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "usr/lib/gtk-3.0/3.0.0/immodules.cache").exists())

    def test_query_failure_fails_build(self):
        self.assertNotEqual(self.run_cache(FAIL_QUERY="1").returncode, 0)

    def test_missing_wayland_registration_fails_build(self):
        result = self.run_cache(OMIT_WAYLAND="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Wayland input module is missing", result.stderr)

    def test_checks_each_installed_graphical_runtime(self):
        binaries = ("/usr/bin/phoc", "/usr/libexec/phosh", "/usr/bin/squeekboard",
                    "/usr/bin/netsurf-gtk3")
        for binary in binaries:
            self.write(self.root / binary.lstrip("/"), "#!/bin/sh\nexit 0\n")
        log = self.work / "loader.log"
        result = self.run_cache(LOADER_LOG=str(log))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(log.read_text().splitlines(), list(binaries))

    def test_runtime_linker_failure_rejects_image(self):
        self.write(self.root / "usr/bin/phoc", "#!/bin/sh\nexit 0\n")
        result = self.run_cache(FAIL_LINKER="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing runtime symbol", result.stderr)
        self.assertFalse((self.root / "usr/lib/gtk-3.0/3.0.0/immodules.cache").exists())


if __name__ == "__main__":
    unittest.main()
