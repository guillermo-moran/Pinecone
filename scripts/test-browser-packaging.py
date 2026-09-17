#!/usr/bin/env python3
"""Offline browser staging/launcher regressions; no Lima or guest execution."""

import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
STAGE = ROOT / "scripts/stage-alpine-graphical-rootfs.sh"
ASSETS = ROOT / "scripts/rootfs"


def write(path, text, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(mode)


def apk(cache, name, version, provides="", files=None):
    info = f"pkgname = {name}\npkgver = {version}\narch = aarch64\n"
    info += "".join(f"provides = {item}\n" for item in provides.split())
    contents = {".PKGINFO": (info, 0o644), **(files or {})}
    with tarfile.open(cache / f"{name}-{version}.apk", "w:gz") as archive:
        for path, (data, mode) in contents.items():
            member = tarfile.TarInfo(path)
            member.size = len(data.encode())
            member.mode = mode
            archive.addfile(member, io.BytesIO(data.encode()))


class StagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="browser-packaging-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.cache = self.work / "cache"
        self.cache.mkdir()
        self.dest = self.work / "rootfs"
        self.selection = self.cache / "selected-graphical-packages-phosh.txt"
        aliases = (
            "cage evtest foot seatd font-dejavu at-spi2-core dbus dbus-daemon-launch-helper elogind phoc "
            "phosh polkit-elogind util-linux-login weston-clients portfolio "
            "gnome-calculator gnome-calendar gnome-clocks gnome-text-editor networkmanager networkmanager-cli"
        )
        self.pin = "main|base+libs|1-r0\n"
        write(self.selection, self.pin)
        apk(self.cache, "base+libs", "1-r0", aliases + " so:libexisting.so.1=1", files={
            "usr/libexec/dbus-daemon-launch-helper": ("#!/bin/sh\nexit 0\n", 0o750),
            "usr/bin/nmcli": ("#!/bin/sh\nexit 0\n", 0o755),
        })
        # The newer index has a different SONAME. It must not replace the pin.
        write(self.cache / "main-APKINDEX", (
            f"P:base+libs\nV:2-r0\np:{aliases} so:libexisting.so.2=2\n\n"
            "P:ca-certificates\nV:1-r0\n\n"
            "P:ca-certificates-bundle\nV:1-r0\n\n"
            "P:new-lib\nV:1-r0\np:so:libnew.so.1=1\nD:so:libexisting.so.1\n\n"
            "P:extra-app\nV:1-r0\nD:so:libnew.so.1\n\n"
        ))
        write(self.cache / "community-APKINDEX", (
            "P:netsurf\nV:3.11-r1\nD:so:libexisting.so.1 so:libnew.so.1\n\n"
        ))
        apk(self.cache, "netsurf", "3.11-r1", files={
            "usr/bin/netsurf-gtk3": ("#!/bin/sh\nexit 0\n", 0o755),
        })
        apk(self.cache, "ca-certificates", "1-r0")
        apk(self.cache, "ca-certificates-bundle", "1-r0", files={
            "etc/ssl/certs/ca-certificates.crt": ("fixture certificate\n", 0o644),
        })
        apk(self.cache, "new-lib", "1-r0", "so:libnew.so.1=1")
        apk(self.cache, "extra-app", "1-r0")
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("ARM64VIZ_", "PINECONE_"))}
        for name in ("WLROOTS", "PHOC", "PHOSH", "SETTINGS", "GLIB", "MUSL"):
            self.env[f"PINECONE_USE_PATCHED_{name}"] = "0"
        self.env.update(ARM64VIZ_GRAPHICAL_PROFILE="phosh",
                        ARM64VIZ_GRAPHICAL_PACKAGE_CACHE=str(self.cache))
        # Any attempted index refresh or package download is a test failure.
        write(self.work / "bin/curl", "#!/bin/sh\necho unexpected-network >&2\nexit 99\n", 0o755)
        self.env["PATH"] = str(self.work / "bin") + os.pathsep + os.environ["PATH"]

    def run_stage(self, **env):
        return subprocess.run(["bash", str(STAGE), str(self.dest)],
                              env={**self.env, **env}, capture_output=True, text=True)

    def test_adds_browser_and_transitive_dependencies_preserving_pin(self):
        result = self.run_stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        selected = self.selection.read_text()
        self.assertTrue(selected.startswith(self.pin))
        self.assertIn("community|netsurf|3.11-r1\n", selected)
        self.assertIn("main|new-lib|1-r0\n", selected)
        self.assertNotIn("|2-r0", selected)
        self.assertTrue(os.access(self.dest / "usr/local/bin/pinecone-launch-browser", os.X_OK))
        desktop = (self.dest / "usr/share/applications/netsurf.desktop").read_text()
        self.assertIn("Exec=/usr/local/bin/pinecone-launch-browser %u", desktop)
        self.assertIn("DBusActivatable=false", desktop)
        self.assertIn("Icon=web-browser-symbolic", desktop)
        self.assertTrue((self.dest / "etc/ssl/certs/ca-certificates.crt").is_file())
        result = self.run_stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.selection.read_text(), selected)

    def test_extra_target_is_not_omitted_on_reuse(self):
        self.assertEqual(self.run_stage().returncode, 0)
        result = self.run_stage(ARM64VIZ_EXTRA_GRAPHICAL_PACKAGES="extra-app")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("main|extra-app|1-r0\n", self.selection.read_text())

    def test_missing_dependency_preserves_selection(self):
        result = self.run_stage(ARM64VIZ_EXTRA_GRAPHICAL_PACKAGES="missing-browser")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unable to resolve", result.stderr)
        self.assertEqual(self.selection.read_text(), self.pin)
        self.assertFalse(list(self.cache.glob("*.staging.*")))

    def test_new_soname_cannot_silently_upgrade_pinned_package(self):
        path = self.cache / "community-APKINDEX"
        write(path, path.read_text().replace("so:libexisting.so.1", "so:libexisting.so.2"))
        result = self.run_stage()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("conflicting with pinned", result.stderr)
        self.assertEqual(self.selection.read_text(), self.pin)

    def test_missing_stale_pin_metadata_is_not_guessed(self):
        (self.cache / "base+libs-1-r0.apk").unlink()
        result = self.run_stage()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing metadata for pinned", result.stderr)
        self.assertEqual(self.selection.read_text(), self.pin)

    def test_failed_download_does_not_poison_cached_archive(self):
        missing = self.cache / "netsurf-3.11-r1.apk"
        missing.unlink()
        write(self.work / "bin/curl", (
            '#!/bin/sh\nwhile [ "$#" -gt 0 ]; do\n'
            '  if [ "$1" = -o ]; then shift; printf partial > "$1"; fi\n'
            '  shift\ndone\nexit 22\n'
        ), 0o755)
        result = self.run_stage()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(missing.exists())
        self.assertFalse(list(self.cache.glob("*.staging.*")))

    def test_invalid_download_is_not_published(self):
        missing = self.cache / "netsurf-3.11-r1.apk"
        missing.unlink()
        write(self.work / "bin/curl", (
            '#!/bin/sh\nwhile [ "$#" -gt 0 ]; do\n'
            '  if [ "$1" = -o ]; then shift; printf not-an-apk > "$1"; fi\n'
            '  shift\ndone\nexit 0\n'
        ), 0o755)
        result = self.run_stage()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(missing.exists())
        self.assertFalse(list(self.cache.glob("*.staging.*")))


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="browser-launcher-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.home = self.work / "home"
        self.home.mkdir()
        self.ca = self.work / "ca.crt"
        write(self.ca, "fixture CA\n")
        self.choices = self.work / "Choices"
        shutil.copyfile(ASSETS / "pinecone-browser.Choices", self.choices)
        # Relocate fixed guest paths in the test copy, not in production code.
        source = (ASSETS / "pinecone-launch-browser").read_text()
        source = source.replace("/etc/ssl/certs/ca-certificates.crt", str(self.ca))
        source = source.replace("/usr/share/pinecone/browser/Choices", str(self.choices))
        self.launcher = self.work / "launcher"
        write(self.launcher, source, 0o755)
        write(self.work / "bin/id", '#!/bin/sh\necho "${TEST_UID:-1000}"\n', 0o755)
        write(self.work / "bin/netsurf-gtk3", (
            '#!/bin/sh\nprintf "%s\\n" "$GDK_BACKEND" "$SSL_CERT_FILE" '
            '"$CURL_CA_BUNDLE" "$@" > "$TEST_CAPTURE"\n'
        ), 0o755)
        self.capture = self.work / "args"
        self.env = {**os.environ, "HOME": str(self.home),
                    "XDG_CONFIG_HOME": str(self.home / ".config"),
                    "XDG_RUNTIME_DIR": str(self.work), "WAYLAND_DISPLAY": "wayland-0",
                    "GDK_BACKEND": "x11", "TEST_CAPTURE": str(self.capture),
                    "PATH": str(self.work / "bin") + os.pathsep + os.environ["PATH"]}
        self.env.pop("WAYLAND_SOCKET", None)

    def run_launcher(self, *args, **env):
        return subprocess.run(["sh", str(self.launcher), *args],
                              env={**self.env, **env}, capture_output=True, text=True)

    def test_default_https_wayland_and_ca(self):
        result = self.run_launcher()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.capture.read_text().splitlines(), [
            "wayland", str(self.ca), str(self.ca), f"--ca_bundle={self.ca}", "https://example.com/",
        ])
        self.assertEqual((self.home / ".config/netsurf/Choices").read_text(), self.choices.read_text())

    def test_preserves_preferences_and_url_argument(self):
        path = self.home / ".config/netsurf/Choices"
        write(path, "window_width:420\n")
        url = "https://example.com/?q=two words&other=yes"
        result = self.run_launcher(url)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(path.read_text(), "window_width:420\n")
        self.assertEqual(self.capture.read_text().splitlines()[-1], url)

    def test_legacy_preferences_are_preserved(self):
        path = self.home / ".netsurf/Choices"
        write(path, "window_width:420\n")
        self.assertEqual(self.run_launcher().returncode, 0)
        self.assertEqual(path.read_text(), "window_width:420\n")
        self.assertFalse((self.home / ".config/netsurf/Choices").exists())

    def test_root_warning_and_unprivileged_launch(self):
        result = self.run_launcher(TEST_UID="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no renderer sandbox", result.stderr)
        result = self.run_launcher(TEST_UID="1000")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("running as root", result.stderr)

    def test_missing_ca_fails_closed(self):
        self.ca.unlink()
        result = self.run_launcher()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CA certificate bundle is missing", result.stderr)
        self.assertFalse(self.capture.exists())

    def test_missing_wayland_fails_closed(self):
        result = self.run_launcher(WAYLAND_DISPLAY="")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.capture.exists())

    def test_url_cannot_inject_browser_options(self):
        result = self.run_launcher("--ca_bundle=/tmp/untrusted")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.capture.exists())


class RealCacheAuditTests(unittest.TestCase):
    def test_netsurf_requirements_already_have_pinned_cached_providers(self):
        cache = ROOT / "artifacts/alpine-packages/edge-aarch64"
        selection = cache / "selected-graphical-packages-phosh.txt"
        if not selection.exists():
            self.skipTest("optional real package cache is absent")
        records = []
        for repo in ("main", "community"):
            for paragraph in (cache / f"{repo}-APKINDEX").read_text().split("\n\n"):
                fields = dict(line.split(":", 1) for line in paragraph.splitlines() if ":" in line)
                if fields.get("P") == "netsurf":
                    records.append(fields)
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["A"], "aarch64")
        available = set()
        for record in selection.read_text().splitlines():
            _, name, version = record.split("|")
            archive = cache / f"{name}-{version}.apk"
            self.assertTrue(archive.exists(), f"missing pinned archive: {archive}")
            info = subprocess.check_output(["bsdtar", "-xOf", str(archive), ".PKGINFO"], text=True)
            available.add(name)
            for line in info.splitlines():
                if line.startswith("provides = "):
                    available.add(line.removeprefix("provides = ").split("=", 1)[0])
        self.assertFalse(set(records[0]["D"].split()) - available,
                         "NetSurf requires a dependency not in the pinned cache")
        self.assertTrue({"ca-certificates", "ca-certificates-bundle"} <= available)


if __name__ == "__main__":
    unittest.main()
