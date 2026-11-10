import base64
import copy
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import release_ios as release
import release_ios17 as ios17


TEAM = "ABCD123456"
CERT = b"synthetic-public-certificate"
DIGEST = hashlib.sha1(CERT).hexdigest().upper()
PROFILE_ID = "12345678-1234-1234-1234-123456789ABC"


def profile():
    return {"ExpirationDate": dt.datetime(2099, 1, 1), "UUID": PROFILE_ID,
            "TeamIdentifier": [TEAM], "ApplicationIdentifierPrefix": ["OLDPREFIX1"],
            "Platform": ["iOS"], "DeveloperCertificates": [CERT],
            "Entitlements": {"com.apple.developer.team-identifier": TEAM,
                             "application-identifier": "OLDPREFIX1." + release.BUNDLE_ID,
                             "get-task-allow": False}}


def copy_privacy_manifest(app):
    source = Path(__file__).resolve().parents[1] / "Sources/App/PrivacyInfo.xcprivacy"
    (app / "PrivacyInfo.xcprivacy").write_bytes(source.read_bytes())


def secret_env():
    env = {name: "synthetic-password" for name in release.SECRET_NAMES}
    env.update(IOS_TEAM_ID=TEAM, IOS_SIGNING_CERTIFICATE_BASE64=base64.b64encode(b"p12").decode(),
               IOS_PROVISION_PROFILE_BASE64=base64.b64encode(b"cms").decode())
    return env


class PrivacyManifestTests(unittest.TestCase):
    def test_packaged_resource_accepts_xml_and_binary(self):
        source = Path(__file__).resolve().parents[1] / "Sources/App/PrivacyInfo.xcprivacy"
        payload = plistlib.loads(source.read_bytes())
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            for fmt in [plistlib.FMT_XML, plistlib.FMT_BINARY]:
                (app / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps(payload, fmt=fmt))
                release.verify_required_reasons(app)

    def test_missing_corrupt_wrong_reason_and_duplicate_entries_fail(self):
        source = Path(__file__).resolve().parents[1] / "Sources/App/PrivacyInfo.xcprivacy"
        payload = plistlib.loads(source.read_bytes())
        missing = copy.deepcopy(payload)
        missing["NSPrivacyAccessedAPITypes"] = missing["NSPrivacyAccessedAPITypes"][:1]
        wrong = copy.deepcopy(payload)
        wrong["NSPrivacyAccessedAPITypes"][1]["NSPrivacyAccessedAPITypeReasons"] = ["8FFB.1"]
        duplicate = copy.deepcopy(payload)
        duplicate["NSPrivacyAccessedAPITypes"].append(copy.deepcopy(duplicate["NSPrivacyAccessedAPITypes"][1]))
        variants = [None, b"not-a-plist", plistlib.dumps(missing), plistlib.dumps(wrong),
                    plistlib.dumps(duplicate), plistlib.dumps([])]
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            target = app / "PrivacyInfo.xcprivacy"
            for index, data in enumerate(variants):
                with self.subTest(index=index):
                    if data is not None: target.write_bytes(data)
                    elif target.exists(): target.unlink()
                    with self.assertRaises(release.ReleaseError):
                        release.verify_required_reasons(app)


class ProfileTests(unittest.TestCase):
    def test_valid_profile_accepts_legacy_app_prefix(self):
        self.assertEqual(release.validate_profile(profile(), TEAM, "app-store-connect"), (PROFILE_ID, {DIGEST}))

    def test_adhoc_requires_registered_devices(self):
        p = profile()
        with self.assertRaises(release.ReleaseError):
            release.validate_profile(p, TEAM, "release-testing")
        p["ProvisionedDevices"] = ["synthetic-udid"]
        release.validate_profile(p, TEAM, "release-testing")
        with self.assertRaises(release.ReleaseError):
            release.validate_profile(p, TEAM, "app-store-connect")

    def test_rejects_expired_wrong_team_wildcard_debug_and_enterprise(self):
        variants = []
        for key, value in [("ExpirationDate", dt.datetime(2000, 1, 1)), ("TeamIdentifier", ["OTHERTEAM1"]),
                           ("UUID", "../../outside"), ("DeveloperCertificates", []),
                           ("ProvisionsAllDevices", True), ("Platform", ["OSX"])]:
            p = profile(); p[key] = value; variants.append(p)
        for key, value in [("application-identifier", "OLDPREFIX1.*"), ("get-task-allow", True),
                           ("com.apple.developer.team-identifier", "OTHERTEAM1")]:
            p = profile(); p["Entitlements"][key] = value; variants.append(p)
        for p in variants:
            with self.subTest(p=p), self.assertRaises(release.ReleaseError):
                release.validate_profile(p, TEAM, "app-store-connect")

    def test_identity_must_be_valid_distribution_and_match_profile(self):
        output = '  1) ' + DIGEST + ' "Apple Distribution: Synthetic"\n 1 valid identities found'
        self.assertEqual(release.matching_identity(output, {DIGEST}), DIGEST)
        for invalid in ["0 valid identities found", output.replace("Distribution", "Development"), output.replace(DIGEST, "0" * 40)]:
            with self.assertRaises(release.ReleaseError):
                release.matching_identity(invalid, {DIGEST})

    def test_secrets_errors_only_name_fields(self):
        with self.assertRaises(release.ReleaseError) as cm:
            release.require_secrets({"IOS_TEAM_ID": "sensitive-value"})
        self.assertIn("IOS_SIGNING_CERTIFICATE_BASE64", str(cm.exception))
        self.assertNotIn("sensitive-value", str(cm.exception))
        release.require_secrets(secret_env())
        for data in ["??private??", ""]:
            with self.assertRaises(release.ReleaseError) as cm:
                release.decode_secret(data, "TEST_SECRET")
            self.assertNotIn("private", str(cm.exception))


class IsolationTests(unittest.TestCase):
    def test_real_child_process_does_not_receive_signing_secrets(self):
        with patch.dict(os.environ, secret_env()):
            output = release.run([sys.executable, "-c", "import os; print('IOS_TEAM_ID' in os.environ)"], "測試")
        self.assertEqual(output.strip(), b"False")

    def test_real_failed_child_never_echoes_arguments_or_output(self):
        with self.assertRaises(release.ReleaseError) as cm:
            release.run([sys.executable, "-c", "import sys; print('synthetic-private-key'); sys.exit(42)"], "測試")
        self.assertIn("42", str(cm.exception))
        self.assertNotIn("synthetic-private-key", str(cm.exception))

    def test_real_signed_preflight_fails_before_xcode_when_secrets_absent(self):
        env = {k: v for k, v in os.environ.items() if k not in release.SECRET_NAMES}
        result = subprocess.run([sys.executable, str(Path(release.__file__)), "preflight", "--signed"],
                                capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode, 1)
        self.assertIn("缺少 GitHub Actions secrets", result.stderr)

    def test_cleanup_runs_after_archive_failure_and_preserves_other_profiles(self):
        calls = []
        def fake_run(args, label, **kwargs):
            calls.append(args)
            if args[1:3] == ["cms", "-D"]:
                return plistlib.dumps(profile())
            if args[1:4] == ["list-keychains", "-d", "user"] and "-s" not in args:
                return b'"/original/login.keychain-db"\n'
            if args[1] == "find-identity":
                return ('  1) ' + DIGEST + ' "Apple Distribution: Synthetic"\n').encode()
            return b""
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            other = home / "Library/MobileDevice/Provisioning Profiles/other.mobileprovision"
            other.parent.mkdir(parents=True)
            other.write_bytes(b"keep")
            with patch.dict(os.environ, secret_env()), patch.object(Path, "home", return_value=home), patch.object(release, "run", side_effect=fake_run):
                with self.assertRaisesRegex(release.ReleaseError, "archive failed"):
                    with release.signing_material("app-store-connect") as signing:
                        self.assertEqual(signing["identity"], DIGEST)
                        self.assertEqual(len(list(home.rglob(PROFILE_ID + ".mobileprovision"))), 2)
                        raise release.ReleaseError("archive failed")
            self.assertEqual(other.read_bytes(), b"keep")
            self.assertEqual(list(home.rglob(PROFILE_ID + ".mobileprovision")), [])
        self.assertIn(["security", "list-keychains", "-d", "user", "-s", "/original/login.keychain-db"], calls)
        self.assertTrue(any(c[1] == "delete-keychain" for c in calls))

    def test_existing_profile_is_not_overwritten_or_deleted(self):
        def fake_run(args, label, **kwargs):
            if args[1] == "cms": return plistlib.dumps(profile())
            if args[1] == "find-identity": return ('1) ' + DIGEST + ' "Apple Distribution: Test"').encode()
            return b""
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            existing = home / "Library/MobileDevice/Provisioning Profiles" / (PROFILE_ID + ".mobileprovision")
            existing.parent.mkdir(parents=True); existing.write_bytes(b"keep")
            with patch.dict(os.environ, secret_env()), patch.object(Path, "home", return_value=home), patch.object(release, "run", side_effect=fake_run):
                with self.assertRaisesRegex(release.ReleaseError, "拒絕覆寫"):
                    with release.signing_material("app-store-connect"):
                        self.fail("must not yield")
            self.assertEqual(existing.read_bytes(), b"keep")


class BuildTests(unittest.TestCase):
    def test_unsigned_build_failure_can_preserve_opt_in_diagnostics(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "device-build.log"
            with self.assertRaises(release.ReleaseError):
                release.run([sys.executable, "-c", "import sys; print('fixture-build-failure'); sys.exit(9)"],
                            "unsigned fixture", diagnostic_log=log)
            self.assertIn("fixture-build-failure", log.read_text())

    def test_isolated_project_retains_relative_debug_plist_input(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            with patch.object(release, "run"):
                project = release.generate_project(root, output)
            self.assertEqual(project.parent, output)
            source = root / "Configuration/Info-Debug.plist"
            copied = output / "Configuration/Info-Debug.plist"
            self.assertEqual(copied.read_bytes(), source.read_bytes())
            self.assertEqual(plistlib.loads(copied.read_bytes())["NSAppTransportSecurity"]["NSExceptionDomains"].keys(), {"127.0.0.1"})

    def test_release_rejects_ats_in_unsigned_and_signed_products(self):
        debug_plist = Path(__file__).resolve().parents[1] / "Configuration/Info-Debug.plist"
        debug_ats = plistlib.loads(debug_plist.read_bytes())["NSAppTransportSecurity"]
        variants = [debug_ats, {}, {"NSAllowsArbitraryLoads": True},
                    {"NSAllowsArbitraryLoadsInWebContent": True}, False]
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Example.app"
            app.mkdir()
            copy_privacy_manifest(app)
            for signed in [False, True]:
                for fmt in [plistlib.FMT_XML, plistlib.FMT_BINARY]:
                    for ats in variants:
                        with self.subTest(signed=signed, fmt=fmt, ats=ats):
                            info = {"CFBundleIdentifier": release.BUNDLE_ID, "CFBundleExecutable": "Example",
                                    "MinimumOSVersion": "17.0", "DTPlatformName": "iphoneos", "UIFileSharingEnabled": True, "LSSupportsOpeningDocumentsInPlace": True,
                                    "NSAppTransportSecurity": ats}
                            (app / "Info.plist").write_bytes(plistlib.dumps(info, fmt=fmt))
                            with patch.object(release, "run") as native_tool:
                                with self.assertRaisesRegex(release.ReleaseError, "NSAppTransportSecurity"):
                                    release.verify_app(app, signed=signed, identity=DIGEST if signed else None)
                                native_tool.assert_not_called()

    def test_release_accepts_no_ats_key_and_reports_product_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Example.app"
            app.mkdir()
            copy_privacy_manifest(app)
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": release.BUNDLE_ID,
                "CFBundleExecutable": "Example", "MinimumOSVersion": "17.0", "DTPlatformName": "iphoneos", "UIFileSharingEnabled": True, "LSSupportsOpeningDocumentsInPlace": True},
                fmt=plistlib.FMT_BINARY))
            (app / "embedded.mobileprovision").write_bytes(b"synthetic")
            def fake_run(args, label, **kwargs):
                if "lipo" in args: return b"arm64"
                if "otool" in args: return b"Load command 1\ncmd LC_BUILD_VERSION\nplatform IOS\nminos 17.0\nsdk 26.2\n"
                if "--extract-certificates" in args:
                    Path(args[3] + "0").write_bytes(CERT)
                return b""
            for signed in [False, True]:
                with self.subTest(signed=signed), patch.object(release, "run", side_effect=fake_run):
                    report = release.verify_app(app, signed=signed, identity=DIGEST if signed else None)
                    self.assertTrue(report["ats_key_absent"])
                    self.assertTrue(report["required_reason_entries_verified"])
                    self.assertEqual(report["signature_verified"], signed)

    def test_adhoc_codesign_seal_cannot_pass_as_distribution(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Example.app"
            app.mkdir()
            copy_privacy_manifest(app)
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": release.BUNDLE_ID,
                "CFBundleExecutable": "Example", "MinimumOSVersion": "17.0", "DTPlatformName": "iphoneos", "UIFileSharingEnabled": True, "LSSupportsOpeningDocumentsInPlace": True}))
            (app / "embedded.mobileprovision").write_bytes(b"synthetic")
            def fake_run(args, label, **kwargs):
                if "lipo" in args: return b"arm64"
                if "otool" in args: return b"Load command 1\ncmd LC_BUILD_VERSION\nplatform IOS\nminos 17.0\nsdk 26.2\n"
                return b""  # seal verifies, but no certificate is extracted
            with patch.object(release, "run", side_effect=fake_run):
                with self.assertRaisesRegex(release.ReleaseError, "distribution"):
                    release.verify_app(app, signed=True, identity=DIGEST)

    def test_exported_certificate_must_equal_selected_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Example.app"
            app.mkdir()
            copy_privacy_manifest(app)
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": release.BUNDLE_ID,
                "CFBundleExecutable": "Example", "MinimumOSVersion": "17.0", "DTPlatformName": "iphoneos", "UIFileSharingEnabled": True, "LSSupportsOpeningDocumentsInPlace": True}))
            (app / "embedded.mobileprovision").write_bytes(b"synthetic")
            def fake_run(args, label, **kwargs):
                if "lipo" in args: return b"arm64"
                if "otool" in args: return b"Load command 1\ncmd LC_BUILD_VERSION\nplatform IOS\nminos 17.0\nsdk 26.2\n"
                if "--extract-certificates" in args:
                    Path(args[3] + "0").write_bytes(CERT)
                return b""
            with patch.object(release, "run", side_effect=fake_run):
                self.assertTrue(release.verify_app(app, signed=True, identity=DIGEST)["signature_verified"])
                with self.assertRaisesRegex(release.ReleaseError, "distribution"):
                    release.verify_app(app, signed=True, identity="0" * 40)

    def test_signing_profile_applies_only_to_app(self):
        graph = {"objects": {
            "app": {"isa": "PBXNativeTarget", "name": "WoowAssistant", "productType": "com.apple.product-type.application", "buildConfigurationList": "appConfigs"},
            "framework": {"isa": "PBXNativeTarget", "productType": "com.apple.product-type.framework", "buildConfigurationList": "frameworkConfigs"},
            "appConfigs": {"buildConfigurations": ["a", "debug"]}, "frameworkConfigs": {"buildConfigurations": ["f"]},
            "a": {"name": "Release", "buildSettings": {"PRODUCT_BUNDLE_IDENTIFIER": release.BUNDLE_ID}},
            "f": {"name": "Release", "buildSettings": {}}, "debug": {"name": "Debug", "buildSettings": {}}}}
        release.configure_signing(graph, TEAM, DIGEST, PROFILE_ID)
        self.assertEqual(graph["objects"]["a"]["buildSettings"]["PROVISIONING_PROFILE_SPECIFIER"], PROFILE_ID)
        self.assertEqual(graph["objects"]["f"]["buildSettings"]["PROVISIONING_PROFILE_SPECIFIER"], "")
        self.assertEqual(graph["objects"]["debug"]["buildSettings"], {})

    def test_minimum_os_cannot_drift_above_17(self):
        rows = [{"target": "WoowAssistant", "buildSettings": {"PRODUCT_BUNDLE_IDENTIFIER": release.BUNDLE_ID, "IPHONEOS_DEPLOYMENT_TARGET": "17.0"}}]
        release.verify_settings(rows)
        for minimum in ["17.1", "18.0", "", "16.0"]:
            bad = copy.deepcopy(rows); bad[0]["buildSettings"]["IPHONEOS_DEPLOYMENT_TARGET"] = minimum
            with self.assertRaises(release.ReleaseError): release.verify_settings(bad)
        rows.append({"target": "Framework", "buildSettings": {"IPHONEOS_DEPLOYMENT_TARGET": "18.0"}})
        with self.assertRaises(release.ReleaseError): release.verify_settings(rows)

    def test_binary_minimum_is_checked_not_only_project_yaml(self):
        release.verify_macho("cmd LC_BUILD_VERSION\n platform IOS\n minos 17.0\n sdk 26.2\n")
        release.verify_macho("cmd LC_BUILD_VERSION\n platform 2\n minos 17.0\n sdk 26.2\n ntools 1\n tool LD\n version 1230.1\n")
        release.verify_macho("cmd LC_VERSION_MIN_IPHONEOS\n version 15.0\n sdk 26.2\n")
        for output in ["", " minos 18.0\n", " minos 17.0\n minos 17.1\n"]:
            with self.assertRaises(release.ReleaseError): release.verify_macho(output)


class RuntimeTests(unittest.TestCase):
    def payload(self):
        return {"runtimes": [{"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-17-0", "version": "17.0.1", "isAvailable": True, "buildversion": "21A342"}]}

    def test_exact_patch_version_not_identifier_suffix(self):
        result = ios17.select_runtime(self.payload(), "17.0.1")
        self.assertEqual(result["version"], "17.0.1")
        with self.assertRaises(release.ReleaseError): ios17.select_runtime(self.payload(), "17.0")

    def test_missing_unavailable_duplicate_and_newer_runtime_never_fall_back(self):
        for payload in [{"runtimes": []}, {"runtimes": self.payload()["runtimes"] * 2},
                        {"runtimes": [dict(self.payload()["runtimes"][0], isAvailable=False)]},
                        {"runtimes": [{"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-5", "version": "18.5", "isAvailable": True}]}]:
            with self.assertRaises(release.ReleaseError): ios17.select_runtime(payload, "17.0.1")
        with self.assertRaises(release.ReleaseError): ios17.select_runtime(self.payload(), "18.5")

    def test_failed_download_preserves_before_after_and_status(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            with patch.object(ios17, "run", return_value=b'{"runtimes": []}'), patch.object(ios17.subprocess, "run", return_value=subprocess.CompletedProcess([], 70)):
                with self.assertRaisesRegex(release.ReleaseError, "woow-ios17"):
                    ios17.ensure_runtime(output, "17.0.1", True)
            self.assertTrue((output / "runtimes-before.json").is_file())
            self.assertTrue((output / "runtimes-after.json").is_file())
            self.assertEqual(json.loads((output / "runtime-download-status.json").read_text())["exit_code"], 70)


if __name__ == "__main__":
    unittest.main()
