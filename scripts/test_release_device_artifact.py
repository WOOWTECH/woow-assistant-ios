import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

import release_device_artifact as device
from release_ios import BUNDLE_ID, ReleaseError


PASSPHRASE = "sV9uK2Aq4Zp7Rj6M8xY3Hn5Bf0Tc1DwQ"


class DeviceArtifactTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)
        self.release = self.root / "release"
        export = self.release / "export"
        export.mkdir(parents=True)
        self.ipa = export / "WoowAssistant.ipa"
        self.ipa.write_bytes(b"fake signed IPA payload for packaging boundary\n" * 8)
        self.report = {
            "bundle_id": BUNDLE_ID, "minimum_os": "17.0", "platform": "iphoneos",
            "build_number": "118", "signature_verified": True,
            "artifact_kind": "signed-local-export", "export_method": "release-testing",
            "ipa_sha256": hashlib.sha256(self.ipa.read_bytes()).hexdigest(),
        }
        self.save_report()
        self.output = self.root / "delivery"

    def save_report(self):
        (self.release / "report.json").write_text(json.dumps(self.report))

    def package(self, password=PASSPHRASE):
        return device.package(self.release, self.output,
                              {device.PASSPHRASE_NAME: password})

    def test_actual_openssl_roundtrip_matches_verified_ad_hoc_ipa(self):
        manifest = self.package()
        encrypted = self.output / "WoowAssistant.ipa.enc"
        self.assertEqual(manifest["ipa_sha256"], self.report["ipa_sha256"])
        self.assertEqual(manifest["encrypted_sha256"], device.digest(encrypted))
        self.assertTrue(encrypted.read_bytes().startswith(b"Salted__"))
        self.assertNotIn(self.ipa.read_bytes(), encrypted.read_bytes())
        self.assertEqual(json.loads((self.output / "manifest.json").read_text()), manifest)
        self.assertFalse(any(path.suffix == ".ipa" for path in self.output.iterdir()))
        restored = self.root / "restored.ipa"
        subprocess.run([str(device.OPENSSL), "enc", "-d", "-aes-256-cbc", "-salt",
                        "-pbkdf2", "-iter", str(device.ITERATIONS), "-md", "sha256",
                        "-in", str(encrypted), "-out", str(restored),
                        "-pass", f"env:{device.PASSPHRASE_NAME}"],
                       env={device.PASSPHRASE_NAME: PASSPHRASE},
                       check=True, capture_output=True)
        self.assertEqual(restored.read_bytes(), self.ipa.read_bytes())

    def test_rejects_missing_or_weak_passphrase_before_output(self):
        for password in ("", "too-short", "a" * 31, "a" * 257, "a" * 32 + "\n"):
            with self.subTest(password_length=len(password)), self.assertRaises(ReleaseError):
                self.package(password)
            self.assertFalse(self.output.exists())

    def test_rejects_wrong_method_unsigned_and_modified_ipa(self):
        for change in ({"export_method": "app-store-connect"},
                       {"signature_verified": False},
                       {"minimum_os": "18.0"},
                       {"build_number": "not-numeric"},
                       {"ipa_sha256": "0" * 64}):
            with self.subTest(change=change):
                self.report.update(change)
                self.save_report()
                with self.assertRaises(ReleaseError):
                    self.package()
                self.assertFalse(self.output.exists())
                self.report = {
                    "bundle_id": BUNDLE_ID, "minimum_os": "17.0", "platform": "iphoneos",
                    "build_number": "118", "signature_verified": True,
                    "artifact_kind": "signed-local-export", "export_method": "release-testing",
                    "ipa_sha256": hashlib.sha256(self.ipa.read_bytes()).hexdigest(),
                }

    def test_removes_partial_delivery_when_encryption_fails(self):
        def fail(args, password):
            (self.output / "WoowAssistant.ipa.enc").write_bytes(b"partial")
            raise ReleaseError("failed")
        with mock.patch.object(device, "_crypt", side_effect=fail):
            with self.assertRaises(ReleaseError):
                self.package()
        self.assertFalse(self.output.exists())

    def test_workflow_retains_only_encrypted_ipa(self):
        workflow = (Path(__file__).resolve().parents[1] /
                    ".github/workflows/release-ios.yml").read_text()
        self.assertIn("signed-device-artifact", workflow)
        self.assertIn("scripts/release_device_artifact.py --release build/release --output build/device-delivery", workflow)
        delivery = workflow.split("- name: 保留加密測試包供實機安裝", 1)[1].split("- name:", 1)[0]
        self.assertIn("build/device-delivery/WoowAssistant.ipa.enc", delivery)
        self.assertIn("build/device-delivery/manifest.json", delivery)
        self.assertNotIn("build/release/export", delivery)
        self.assertIn("retention-days: 1", delivery)


if __name__ == "__main__":
    unittest.main()
