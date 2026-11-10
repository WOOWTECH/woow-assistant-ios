import base64
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout, redirect_stderr
from unittest.mock import patch

import release_ios as release
import release_testflight as upload


KEY = b"-----BEGIN PRIVATE KEY-----\nU1lOVEhFVElDX05PVF9BX1JFQUxfS0VZ\n-----END PRIVATE KEY-----\n"


def environment():
    return {"ASC_KEY_ID": "ABC123DEF4", "ASC_ISSUER_ID": "12345678-1234-1234-1234-123456789abc",
            "ASC_PRIVATE_KEY_BASE64": base64.b64encode(KEY).decode(),
            "IOS_SIGNING_CERTIFICATE_PASSWORD": "synthetic-signing-secret", "PATH": os.environ["PATH"]}


def fixture(folder):
    (folder / "export").mkdir()
    ipa = folder / "export/App.ipa"
    ipa.write_bytes(b"synthetic-signed-artifact")
    data = {"signature_verified": True, "bundle_id": release.BUNDLE_ID,
            "artifact_kind": "signed-local-export", "export_method": "app-store-connect",
            "ipa_sha256": hashlib.sha256(ipa.read_bytes()).hexdigest()}
    (folder / "report.json").write_text(json.dumps(data))
    return data


def executable(folder):
    path = folder / "synthetic-transporter"
    path.write_text("#!/bin/sh\nexit 127\n")
    path.chmod(0o700)
    return path


class UploadTests(unittest.TestCase):
    def test_preflight_rejects_missing_and_malformed_credentials(self):
        for change in [{"ASC_KEY_ID": "../other"}, {"ASC_ISSUER_ID": "not-an-id"},
                       {"ASC_PRIVATE_KEY_BASE64": "bad!"}, {"ASC_PRIVATE_KEY_BASE64": base64.b64encode(b"not a key").decode()}]:
            with self.subTest(change=next(iter(change))):
                env = environment(); env.update(change)
                with self.assertRaises(release.ReleaseError): upload.credentials(env)
        with self.assertRaises(release.ReleaseError): upload.credentials({})

    def test_only_verified_unchanged_app_store_export_can_reach_transporter(self):
        for change in [{"signature_verified": False}, {"signature_verified": "true"},
                       {"bundle_id": "other.app"}, {"artifact_kind": "unsigned-device-build-not-installable"},
                       {"export_method": "release-testing"}, {"ipa_sha256": "0" * 64}]:
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                folder = Path(directory); report = fixture(folder); report.update(change)
                (folder / "report.json").write_text(json.dumps(report))
                with patch.dict(os.environ, environment(), clear=True), patch.object(upload, "TRANSPORTER", executable(folder)), patch.object(upload.subprocess, "run") as tool:
                    with self.assertRaises(release.ReleaseError): upload.upload(folder)
                    tool.assert_not_called()
                self.assertFalse((folder / "upload-report.json").exists())

    def test_outcomes_cleanup_secret_isolation_and_no_implicit_replay(self):
        for outcome in [0, 1, "timeout", "missing"]:
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as directory:
                folder = Path(directory); fixture(folder); locations = []
                def tool(args, **kwargs):
                    self.assertEqual(args[:3], [str(folder / "synthetic-transporter"), "-m", "upload"])
                    self.assertTrue(Path(args[args.index("-assetFile") + 1]).samefile(folder / "export/App.ipa"))
                    private = Path(kwargs["cwd"]); locations.append(private)
                    key = private / "private_keys/AuthKey_ABC123DEF4.p8"
                    self.assertEqual(key.read_bytes(), KEY)
                    self.assertEqual(stat.S_IMODE(key.stat().st_mode), 0o600)
                    self.assertFalse(set(release.SECRET_NAMES + upload.UPLOAD_SECRETS) & kwargs["env"].keys())
                    if outcome == "timeout": raise subprocess.TimeoutExpired(args, 1800, output=b"PRIVATE ACCOUNT INFO")
                    if outcome == "missing": raise FileNotFoundError("PRIVATE ACCOUNT INFO")
                    return subprocess.CompletedProcess(args, outcome, stdout=b"PRIVATE ACCOUNT INFO", stderr=KEY)
                console = io.StringIO()
                with patch.dict(os.environ, environment(), clear=True), patch.object(upload, "TRANSPORTER", executable(folder)), patch.object(upload.subprocess, "run", side_effect=tool) as process, \
                     redirect_stdout(console), redirect_stderr(console):
                    if outcome == 0: upload.upload(folder)
                    else:
                        with self.assertRaises(release.ReleaseError): upload.upload(folder)
                    self.assertEqual(process.call_count, 1)
                    with self.assertRaisesRegex(release.ReleaseError, "已有上傳紀錄"): upload.upload(folder)
                    self.assertEqual(process.call_count, 1)
                report = json.loads((folder / "upload-report.json").read_text())
                self.assertEqual(report["upload_accepted"], True if outcome == 0 else None)
                self.assertEqual(report["upload_attempted"], outcome != "missing")
                self.assertFalse(report["processing_verified"])
                self.assertIsNone(report["testflight_available"])
                self.assertTrue(all(not p.exists() for p in locations))
                self.assertEqual(console.getvalue(), "")
                self.assertNotIn("PRIVATE", json.dumps(report))

    def test_missing_transporter_never_attempts_upload(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory); fixture(folder)
            with patch.object(upload, "TRANSPORTER", folder / "missing"), patch.object(upload.subprocess, "run") as tool:
                with self.assertRaisesRegex(release.ReleaseError, "尚未安裝 Apple Transporter"):
                    upload.upload(folder)
                tool.assert_not_called()
            self.assertFalse((folder / "upload-report.json").exists())

    def test_build_number_is_validated_before_any_external_command(self):
        for number in ["0", "-1", "1;echo", "$(true)", "1\nOTHER=YES", "9" * 19]:
            with self.subTest(number=number), patch.object(release, "toolchain") as tool:
                with self.assertRaises(release.ReleaseError):
                    release.build(Path("."), Path("unused"), True, "app-store-connect", number)
                tool.assert_not_called()

    def test_actual_package_must_have_requested_build_number(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleVersion": "1"}))
            with patch.object(release, "run") as tool:
                with self.assertRaisesRegex(release.ReleaseError, "實際產物建置編號"):
                    release.verify_app(app, expected_build_number="42")
                tool.assert_not_called()


if __name__ == "__main__":
    unittest.main()
