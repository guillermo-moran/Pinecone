#!/usr/bin/env python3
"""Offline packaging regressions; real APK transactions are checked in Alpine."""
import importlib.util
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("browser", ROOT / "scripts/test-browser-packaging.py")
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)


class PackageManagerTests(unittest.TestCase):
    def test_archive_manifest_matches_selected_packages(self):
        fixture = fixtures.StagingTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        manifest = fixture.work / "apk-manifest"
        result = fixture.run_stage(PINECONE_APK_MANIFEST_OUT=str(manifest))
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = []
        for line in manifest.read_text().splitlines():
            archive, name, version = line.split("|")
            self.assertTrue(Path(archive).is_file())
            actual.append((name, version))
        expected = [tuple(line.split("|")[1:]) for line in fixture.selection.read_text().splitlines()]
        self.assertEqual(actual, expected)

    def test_transaction_boundary_keeps_signature_checks(self):
        registration = (ROOT / "scripts/register-rootfs-packages.sh").read_text()
        app = (ROOT / "scripts/rootfs/pinecone-packages.c").read_text()
        self.assertIn('--virtual .pinecone-platform', registration)
        self.assertIn('g_subprocess_launcher_spawnv', app)
        for prohibited in ("--allow-untrusted", "--force-overwrite", "--force-broken-world"):
            self.assertNotIn(prohibited, registration + app)

    def test_desktop_is_in_manifest_and_uses_guest_launcher(self):
        build = (ROOT / "scripts/build-arm64-rootfs-image.sh").read_text()
        desktop = (ROOT / "scripts/rootfs/pinecone-packages.desktop").read_text()
        self.assertIn("me.gmoran.pinecone.packages.desktop\n", build)
        self.assertIn("DBusActivatable=false", desktop)
        self.assertIn("Exec=/usr/local/bin/pinecone-launch-packages", desktop)
        self.assertIn("X-Purism-FormFactor=Workstation;Mobile;", desktop)

    def test_boot_preserves_repository_customization(self):
        source = (ROOT / "scripts/rootfs/arm64viz-root-init").read_text()
        self.assertIn('if [ ! -s /etc/apk/repositories ]; then', source)

    def test_shell_syntax(self):
        for name in ("build-pinecone-packages.sh", "register-rootfs-packages.sh",
                     "build-arm64-rootfs-image.sh", "stage-alpine-graphical-rootfs.sh"):
            subprocess.run(["bash", "-n", str(ROOT / "scripts" / name)], check=True)
        for name in ("pinecone-launch-packages", "arm64viz-root-init"):
            subprocess.run(["sh", "-n", str(ROOT / "scripts/rootfs" / name)], check=True)


if __name__ == "__main__":
    unittest.main()
