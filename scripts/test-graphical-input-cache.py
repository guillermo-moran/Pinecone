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
        self.write(self.bin / "uname", '#!/bin/sh\necho "${TEST_SYSTEM:-Linux}"\n')
        self.write(self.bin / "id", '#!/bin/sh\necho "${TEST_UID:-0}"\n')
        self.write(self.bin / "sudo", '#!/bin/sh\nexec "$@"\n')
        self.write(self.bin / "limactl", '''#!/bin/sh
case "$1" in
  start) exit 0 ;;
  copy) cp "${2#fixture:}" "${3#fixture:}" ;;
  shell) shift 4; exec "$@" ;;
  *) exit 97 ;;
esac
''')
        self.write(self.bin / "chroot", '''#!/bin/sh
case "$2" in
  */ld-musl-aarch64.so.1)
    [ "$3" = --list ] || exit 98
    [ "${FAIL_LINKER:-0}" = 0 ] || { echo 'missing runtime symbol' >&2; exit 9; }
    printf '%s\\n' "$4" >> "$LOADER_LOG"
    ;;
  */fc-cache) mkdir -p "$1/var/cache/fontconfig"; touch "$1/var/cache/fontconfig/test-cache-8" ;;
  */gio-querymodules)
    [ "${FAIL_GIO:-0}" = 0 ] || exit 8
    printf '%s\\n' "$3" >> "$GIO_LOG"
    if [ "${EMPTY_GIO:-0}" = 1 ]; then
      rm -f "$1$3/giomodule.cache"
    else
      printf 'libfixture.so: fixture-extension\\n' > "$1$3/giomodule.cache"
    fi
    ;;
  */gdk-pixbuf-query-loaders) echo pixbuf ;;
  */gtk-update-icon-cache|*/gtk4-update-icon-cache)
    printf '%s\\n' "$2 $3 ${4:-} ${5:-}" >> "$ICON_LOG"
    if [ "$3" = --validate ]; then
      [ "${FAIL_ICON_VALIDATE:-0}" = 0 ] || exit 6
      [ -s "$1$4/icon-theme.cache" ] || exit 5
    else
      [ "$3" = --force ] && [ "$4" = --index-only ] || exit 4
      [ "${FAIL_ICON:-0}" = 0 ] || exit 3
      [ "${OMIT_ICON:-0}" = 0 ] || exit 0
      printf 'fixture icon index\\n' > "$1$5/icon-theme.cache"
      if [ "${OLD_ICON_MTIME:-0}" = 1 ]; then
        touch -t 197001010000.00 "$1$5/icon-theme.cache"
      fi
    fi
    ;;
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

    def add_gio(self):
        self.write(self.root / "usr/bin/gio-querymodules", "#!/bin/sh\nexit 0\n")
        for directory in ("usr/lib/gio/modules", "usr/lib/gtk-4.0"):
            self.write(self.root / directory / "libfixture.so", "module bytes\n")
            self.write(self.root / directory / "giomodule.cache", "stale\n")
        return self.work / "gio.log"

    def test_gio_cache_native_and_lima_copyback(self):
        for system in ("Linux", "Darwin"):
            with self.subTest(system=system):
                log = self.add_gio()
                log.unlink(missing_ok=True)
                result = self.run_cache(TEST_SYSTEM=system, GIO_LOG=str(log),
                                        PINECONE_CACHE_LIMA_INSTANCE="fixture")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(log.read_text().splitlines(),
                                 ["/usr/lib/gio/modules", "/usr/lib/gtk-4.0"])
                for directory in ("usr/lib/gio/modules", "usr/lib/gtk-4.0"):
                    self.assertEqual((self.root / directory / "giomodule.cache").read_text(),
                                     "libfixture.so: fixture-extension\n")
                    self.assertEqual((self.root / directory / "libfixture.so").read_text(),
                                     "module bytes\n")

    def test_gio_query_failure_rejects_native_and_lima(self):
        log = self.add_gio()
        for system in ("Linux", "Darwin"):
            result = self.run_cache(TEST_SYSTEM=system, GIO_LOG=str(log), FAIL_GIO="1",
                                    PINECONE_CACHE_LIMA_INSTANCE="fixture")
            self.assertNotEqual(result.returncode, 0)

    def test_missing_gio_tool_rejects_module_directories(self):
        self.add_gio()
        (self.root / "usr/bin/gio-querymodules").unlink()
        result = self.run_cache()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing aarch64 gio-querymodules", result.stderr)

    def test_unprivileged_linux_passes_quoted_root_as_argument(self):
        quoted_root = self.work / "root's cache"
        self.root.rename(quoted_root)
        self.root = quoted_root
        log = self.add_gio()
        result = self.run_cache(TEST_UID="1000", GIO_LOG=str(log))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(log.read_text().splitlines(),
                         ["/usr/lib/gio/modules", "/usr/lib/gtk-4.0"])

    def test_gio_empty_query_removes_stale_cache_in_both_paths(self):
        for system in ("Linux", "Darwin"):
            log = self.add_gio()
            result = self.run_cache(TEST_SYSTEM=system, GIO_LOG=str(log), EMPTY_GIO="1",
                                    PINECONE_CACHE_LIMA_INSTANCE="fixture")
            self.assertEqual(result.returncode, 0, result.stderr)
            for directory in ("usr/lib/gio/modules", "usr/lib/gtk-4.0"):
                self.assertFalse((self.root / directory / "giomodule.cache").exists())

    def add_icons(self, tool="gtk-update-icon-cache"):
        self.write(self.root / "usr/bin" / tool, "#!/bin/sh\nexit 0\n")
        for theme in ("hicolor", "Adwaita", "Theme With Spaces"):
            self.write(self.root / "usr/share/icons" / theme / "index.theme",
                       "[Icon Theme]\nName=Fixture\n")
            self.write(self.root / "usr/share/icons" / theme / "scalable/apps/test.svg",
                       "unchanged image bytes\n")
        self.write(self.root / "usr/share/icons/loose/not-a-theme.svg", "loose icon\n")
        return self.work / "icons.log"

    def test_icons_native_sudo_and_lima_copyback(self):
        for system, uid in (("Linux", "0"), ("Linux", "1000"), ("Darwin", "0")):
            with self.subTest(system=system, uid=uid):
                log = self.add_icons()
                log.unlink(missing_ok=True)
                result = self.run_cache(TEST_SYSTEM=system, TEST_UID=uid, ICON_LOG=str(log),
                                        PINECONE_CACHE_LIMA_INSTANCE="fixture")
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = log.read_text().splitlines()
                self.assertEqual(len(calls), 6)
                for theme in ("hicolor", "Adwaita", "Theme With Spaces"):
                    directory = self.root / "usr/share/icons" / theme
                    self.assertEqual((directory / "icon-theme.cache").read_text(),
                                     "fixture icon index\n")
                    self.assertEqual((directory / "scalable/apps/test.svg").read_text(),
                                     "unchanged image bytes\n")
                    self.assertIn("/usr/bin/gtk-update-icon-cache --force --index-only "
                                  f"/usr/share/icons/{theme}", calls)
                    self.assertIn("/usr/bin/gtk-update-icon-cache --validate "
                                  f"/usr/share/icons/{theme} ", calls)
                self.assertFalse((self.root / "usr/share/icons/loose/icon-theme.cache").exists())

    def test_gtk4_only_icon_tool(self):
        log = self.add_icons(tool="gtk4-update-icon-cache")
        (self.root / "usr/lib/libgtk-3.so.0").unlink()
        (self.root / "usr/bin/gtk-query-immodules-3.0").unlink()
        result = self.run_cache(ICON_LOG=str(log))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("/usr/bin/gtk4-update-icon-cache --force", log.read_text())

    def test_icon_copyback_preserves_theme_and_refreshes_cache_mtime(self):
        log = self.add_icons()
        result = self.run_cache(TEST_SYSTEM="Darwin", ICON_LOG=str(log), OLD_ICON_MTIME="1",
                                PINECONE_CACHE_LIMA_INSTANCE="fixture")
        self.assertEqual(result.returncode, 0, result.stderr)
        for theme in ("hicolor", "Adwaita", "Theme With Spaces"):
            directory = self.root / "usr/share/icons" / theme
            self.assertGreaterEqual((directory / "icon-theme.cache").stat().st_mtime_ns,
                                    directory.stat().st_mtime_ns)

    def test_missing_icon_tool_fails_native_and_lima(self):
        self.add_icons()
        (self.root / "usr/bin/gtk-update-icon-cache").unlink()
        for system in ("Linux", "Darwin"):
            result = self.run_cache(TEST_SYSTEM=system, PINECONE_CACHE_LIMA_INSTANCE="fixture")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing aarch64 gtk-update-icon-cache", result.stderr)

    def test_icon_generation_validation_and_missing_output_fail(self):
        log = self.add_icons()
        for system in ("Linux", "Darwin"):
            for failure in ("FAIL_ICON", "FAIL_ICON_VALIDATE", "OMIT_ICON"):
                with self.subTest(system=system, failure=failure):
                    for cache in self.root.glob("usr/share/icons/*/icon-theme.cache"):
                        cache.unlink()
                    result = self.run_cache(TEST_SYSTEM=system, ICON_LOG=str(log),
                                            PINECONE_CACHE_LIMA_INSTANCE="fixture",
                                            **{failure: "1"})
                    self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
