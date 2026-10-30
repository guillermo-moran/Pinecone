#!/usr/bin/env python3
"""Offline regression of the production custom-APK dependency resolver."""

import importlib.util
import io
from pathlib import Path
import shutil
import subprocess
import tarfile
import unittest


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("browser_fixtures", HERE / "test-browser-packaging.py")
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)

OVERLAYS = {
    "WLROOTS": ("wlroots0.20", "0.20.2-r6", "pinecone-wlroots"),
    "PHOC": ("phoc", "0.57.0-r7", "pinecone-phoc"),
    "PHOSH": ("phosh", "0.57.0-r8", "pinecone-phosh"),
    "SETTINGS": ("gnome-control-center", "50.4-r2", "pinecone-gnome-control-center"),
    "GLIB": ("glib", "2.88.3-r1", "pinecone-glib"),
    "MUSL": ("musl", "1.2.6-r10", "pinecone-musl"),
}


def apk(directory, name, version, dependencies=(), provides=(), files=None):
    directory.mkdir(parents=True, exist_ok=True)
    info = f"pkgname = {name}\npkgver = {version}\narch = aarch64\n"
    info += "".join(f"depend = {item}\n" for item in dependencies)
    info += "".join(f"provides = {item}\n" for item in provides)
    libraries = {f"usr/lib/{item[3:].split('=')[0]}": "fixture library"
                 for item in provides if item.startswith("so:")}
    with tarfile.open(directory / f"{name}-{version}.apk", "w:gz") as archive:
        for path, text in {".PKGINFO": info, **libraries, **(files or {})}.items():
            member = tarfile.TarInfo(path)
            member.size = len(text.encode())
            archive.addfile(member, io.BytesIO(text.encode()))


class OverlayTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.StagingTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.cache = self.fixture.cache
        self.dest = self.fixture.dest
        self.selection = self.fixture.selection
        self.repo = self.fixture.work / "repo"
        (self.repo / "scripts").mkdir(parents=True)
        self.stage = self.repo / "scripts" / fixtures.STAGE.name
        shutil.copyfile(fixtures.STAGE, self.stage)
        (self.repo / "scripts/rootfs").symlink_to(fixtures.ASSETS, target_is_directory=True)
        self.env = dict(self.fixture.env)
        # The older browser fixtures exercise metadata only. Give their pinned
        # library a real file for the new post-extraction SONAME guard.
        base = self.cache / "base+libs-1-r0.apk"
        with tarfile.open(base) as archive:
            files = {item.name: (archive.extractfile(item).read().decode(), item.mode)
                     for item in archive.getmembers()}
        provides = " ".join(line.split(" = ", 1)[1]
                            for line in files.pop(".PKGINFO")[0].splitlines()
                            if line.startswith("provides = "))
        files["usr/lib/libexisting.so.1"] = ("fixture library", 0o644)
        fixtures.apk(self.cache, "base+libs", "1-r0", provides, files)

    def overlay(self, kind, dependencies=(), provides=()):
        name, version, directory = OVERLAYS[kind]
        self.env[f"PINECONE_USE_PATCHED_{kind}"] = "1"
        apk(self.repo / "artifacts/alpine-packages" / directory / "aarch64",
            name, version, dependencies, provides, {f"overlay/{name}": version})

    def index(self, text):
        path = self.cache / "community-APKINDEX"
        path.write_text(path.read_text() + text)

    def run_stage(self):
        return subprocess.run(["bash", str(self.stage), str(self.dest)], env=self.env,
                              capture_output=True, text=True, timeout=30)

    def assert_rejected(self, message):
        before = self.selection.read_bytes()
        result = self.run_stage()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(message, result.stderr)
        self.assertEqual(self.selection.read_bytes(), before)
        self.assertFalse(list(self.dest.rglob("*")), "failure must precede any APK extraction")
        self.assertFalse(list(self.cache.glob("*.staging.*")))
        self.assertFalse(list(self.cache.glob("*.overlays.*")))

    def test_all_custom_apks_require_actual_runtime_dependencies(self):
        for kind in OVERLAYS:
            with self.subTest(kind=kind):
                self.overlay(kind, ("so:libgnome-desktop-3.so.21",))
                self.assert_rejected("so:libgnome-desktop-3.so.21")
                self.env[f"PINECONE_USE_PATCHED_{kind}"] = "0"

    def test_previous_musl_can_be_selected_explicitly(self):
        self.env["PINECONE_USE_PATCHED_MUSL"] = "1"
        self.env["PINECONE_MUSL_PACKAGE_VERSION"] = "1.2.6-r8"
        apk(self.repo / "artifacts/alpine-packages/pinecone-musl/aarch64",
            "musl", "1.2.6-r8", files={"overlay/musl": "1.2.6-r8"})
        result = self.run_stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.dest / "overlay/musl").read_text(), "1.2.6-r8")

    def test_unknown_musl_version_rejected_before_extraction(self):
        self.env["PINECONE_USE_PATCHED_MUSL"] = "1"
        self.env["PINECONE_MUSL_PACKAGE_VERSION"] = "unexpected"
        self.assert_rejected("Unsupported Pinecone musl package version")

    def test_expands_transitive_actual_apk_metadata_preserving_pins(self):
        self.overlay("PHOC", ("so:liboverlay.so.1",))
        self.index("P:overlay-lib\nV:1-r0\np:so:liboverlay.so.1=1\n\n"
                   "P:transitive-lib\nV:1-r0\np:so:libtransitive.so.1=1\n\n")
        apk(self.cache, "overlay-lib", "1-r0", ("so:libtransitive.so.1",), ("so:liboverlay.so.1=1",))
        apk(self.cache, "transitive-lib", "1-r0", ("so:libexisting.so.1",), ("so:libtransitive.so.1=1",))
        result = self.run_stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        selected = self.selection.read_text()
        self.assertTrue(selected.startswith(self.fixture.pin))
        self.assertIn("community|overlay-lib|1-r0\n", selected)
        self.assertIn("community|transitive-lib|1-r0\n", selected)
        self.assertEqual((self.dest / "overlay/phoc").read_text(), "0.57.0-r7")
        self.assertEqual(self.run_stage().returncode, 0)
        self.assertEqual(self.selection.read_text(), selected)

    def test_overlay_cannot_upgrade_a_pinned_provider_for_new_soname(self):
        self.overlay("PHOC", ("so:libexisting.so.2",))
        self.assert_rejected("conflicting with pinned")

    def test_cached_old_abi_is_not_supplied_by_an_overridden_package(self):
        self.selection.write_text(self.selection.read_text() + "main|glib|1-r0\n")
        apk(self.cache, "glib", "1-r0", provides=("so:libold-glib.so.0=0",))
        self.overlay("GLIB", provides=("so:libnew-glib.so.0=0",))
        self.overlay("PHOC", ("so:libold-glib.so.0",))
        self.assert_rejected("so:libold-glib.so.0")

    def test_retained_pinned_consumer_must_survive_overlay_abi_replacement(self):
        self.selection.write_text(self.selection.read_text() + "main|glib|1-r0\nmain|consumer|1-r0\n")
        apk(self.cache, "glib", "1-r0", provides=("so:libold-glib.so.0=0",))
        apk(self.cache, "consumer", "1-r0", ("so:libold-glib.so.0",))
        self.overlay("GLIB", provides=("so:libnew-glib.so.0=0",))
        self.assert_rejected("so:libold-glib.so.0")

    def test_multiple_overlays_supply_each_others_dependencies(self):
        self.overlay("PHOC", ("so:libnew-glib.so.0",))
        self.overlay("GLIB", provides=("so:libnew-glib.so.0=0",))
        self.selection.write_text(self.selection.read_text() + "main|glib|1-r0\n")
        apk(self.cache, "glib", "1-r0", ("so:libobsolete.so.0",), files={"overlay/official-glib": "old"})
        result = self.run_stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("main|glib|1-r0\n", self.selection.read_text())
        self.assertFalse((self.dest / "overlay/official-glib").exists())
        self.assertTrue((self.dest / "overlay/glib").exists())

    def test_actual_apk_must_supply_index_advertised_abi(self):
        self.overlay("PHOC", ("so:libliar.so.1",))
        self.index("P:liar\nV:1-r0\np:so:libliar.so.1=1\n\n")
        apk(self.cache, "liar", "1-r0", provides=("so:libliar.so.0=0",))
        self.assert_rejected("does not provide so:libliar.so.1")

    def test_visited_pin_does_not_inherit_index_only_provides(self):
        self.selection.write_text(self.selection.read_text() + "community|liar|1-r0\n")
        apk(self.cache, "liar", "1-r0", provides=("so:libliar.so.0=0",))
        self.index("P:liar\nV:1-r0\np:so:libliar.so.1=1\n\n")
        self.overlay("PHOC", ("so:libliar.so.1",))
        self.assert_rejected("so:libliar.so.1")

    def test_validation_only_never_extracts_or_publishes_selection(self):
        self.overlay("PHOC", ("so:libexisting.so.1",))
        self.env["ARM64VIZ_GRAPHICAL_VALIDATE_ONLY"] = "1"
        before = self.selection.read_bytes()
        result = self.run_stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.selection.read_bytes(), before)
        self.assertFalse(list(self.dest.rglob("*")))

    def test_provided_soname_must_exist_after_extraction(self):
        self.overlay("PHOC", ("so:libnew.so.1",))
        before = self.selection.read_bytes()
        # new-lib's legacy fixture advertises this SONAME but contains no file.
        result = self.run_stage()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing staged overlay runtime libraries", result.stderr)
        self.assertIn("so:libnew.so.1", result.stderr)
        self.assertEqual(self.selection.read_bytes(), before)

    def test_absolute_library_symlinks_resolve_in_guest_root(self):
        self.overlay("PHOC", ("so:libnew.so.1",))
        lib = self.dest / "usr/lib"
        lib.mkdir(parents=True)
        (lib / "libnew-real.so").write_text("fixture library")
        (lib / "libnew.so.1").symlink_to("/usr/lib/libnew-real.so")
        result = self.run_stage()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_broken_library_symlink_is_not_a_provider(self):
        self.overlay("PHOC", ("so:libnew.so.1",))
        lib = self.dest / "usr/lib"
        lib.mkdir(parents=True)
        (lib / "libnew.so.1").symlink_to("/missing-library.so")
        result = self.run_stage()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing staged overlay runtime libraries", result.stderr)


if __name__ == "__main__":
    unittest.main()
