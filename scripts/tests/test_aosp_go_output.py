"""Check the Go artifact gate with synthetic installed-file trees, not ROMs."""
from pathlib import Path
import subprocess
import tempfile
import unittest


VERIFY = Path(__file__).resolve().parents[1] / "lineageos-lean/verify-output.sh"


class AOSPGoOutputTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="pinecone-go-output-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        for name in (
            "boot.img", "vendor_boot.img", "system/bin/surfaceflinger",
            "system/priv-app/SystemUI/SystemUI.apk",
            "system/priv-app/Settings/Settings.apk",
            "system/priv-app/Launcher3QuickStepGo/Launcher3QuickStepGo.apk",
            "system/priv-app/Provision/Provision.apk", "system/apex/runtime.apex",
        ):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        (self.root / "system/build.prop").write_text(
            "ro.build.type=user\nro.config.low_ram=true\n")

    def verify(self):
        return subprocess.run(["bash", str(VERIFY), str(self.root)],
                              text=True, capture_output=True)

    def test_complete_go_contract_passes(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_non_go_output_fails(self):
        (self.root / "system/build.prop").write_text("ro.build.type=user\n")
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ro.config.low_ram=true", result.stderr)

    def test_missing_provisioner_fails(self):
        (self.root / "system/priv-app/Provision/Provision.apk").unlink()
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Provision.apk", result.stderr)

    def test_setup_wizard_or_google_payload_fails(self):
        for name in ("LineageSetupWizard.apk", "PrebuiltGmsCore.apk", "Phonesky.apk"):
            with self.subTest(name=name):
                path = self.root / "system" / name
                path.touch()
                result = self.verify()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("unexpectedly contains", result.stderr)
                path.unlink()


if __name__ == "__main__":
    unittest.main()
