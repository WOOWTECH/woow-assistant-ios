import base64
import copy
import datetime as dt
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest.mock import patch

import release_ios as release
import release_ios17 as ios17


TEAM = "ABCD123456"
CERT = b"synthetic-public-certificate"
DIGEST = hashlib.sha1(CERT).hexdigest().upper()
PROFILE_ID = "12345678-1234-1234-1234-123456789ABC"
MEDIA_PURPOSES = {"NSCameraUsageDescription": "User approved website camera access.",
                  "NSMicrophoneUsageDescription": "User approved website microphone access."}


def synthetic_xctest_completion(scope):
    """Command fixtures, not a claim that any native XCTest ran locally."""
    catalog = ios17.ui_inventory(Path(__file__).resolve().parents[1])
    selected = ios17.selected_ui_tests(catalog, scope)
    log = "".join("Test Case '-[%s.%s %s]' passed (0.001 seconds).\n" % tuple(t.split("/"))
                  for t in selected).encode()
    ui_only = bool(ios17.TEST_SCOPES[scope]) and all(
        s.startswith("WoowAssistantUITests/") for s in ios17.TEST_SCOPES[scope])
    count = len(selected) + (0 if ui_only else 1)
    return log, {"result": "Passed", "totalTestCount": count, "passedTests": count,
                 "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}


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
        missing_selected_file = copy.deepcopy(payload)
        missing_selected_file["NSPrivacyAccessedAPITypes"] = [entry for entry in missing_selected_file["NSPrivacyAccessedAPITypes"]
            if entry["NSPrivacyAccessedAPIType"] != "NSPrivacyAccessedAPICategoryFileTimestamp"]
        wrong_selected_file = copy.deepcopy(payload)
        for entry in wrong_selected_file["NSPrivacyAccessedAPITypes"]:
            if entry["NSPrivacyAccessedAPIType"] == "NSPrivacyAccessedAPICategoryFileTimestamp":
                entry["NSPrivacyAccessedAPITypeReasons"] = ["C617.1"]
        variants = [None, b"not-a-plist", plistlib.dumps(missing), plistlib.dumps(wrong),
                    plistlib.dumps(duplicate), plistlib.dumps([]), plistlib.dumps(missing_selected_file), plistlib.dumps(wrong_selected_file)]
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

    def test_release_rejects_missing_or_blank_browser_media_purpose_strings(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Example.app"
            app.mkdir()
            base = {"CFBundleIdentifier": release.BUNDLE_ID, "CFBundleExecutable": "Example",
                    "MinimumOSVersion": "17.0", "DTPlatformName": "iphoneos",
                    "UIFileSharingEnabled": True, "LSSupportsOpeningDocumentsInPlace": True,
                    **MEDIA_PURPOSES}
            for key in MEDIA_PURPOSES:
                for value in (None, "", "  "):
                    with self.subTest(key=key, value=value):
                        info = dict(base)
                        if value is None:
                            info.pop(key)
                        else:
                            info[key] = value
                        (app / "Info.plist").write_bytes(plistlib.dumps(info))
                        with patch.object(release, "run") as native_tool:
                            with self.assertRaisesRegex(release.ReleaseError, key):
                                release.verify_app(app)
                            native_tool.assert_not_called()

    def test_release_accepts_no_ats_key_and_reports_product_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Example.app"
            app.mkdir()
            copy_privacy_manifest(app)
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": release.BUNDLE_ID,
                "CFBundleExecutable": "Example", "MinimumOSVersion": "17.0", "DTPlatformName": "iphoneos", "UIFileSharingEnabled": True, "LSSupportsOpeningDocumentsInPlace": True, **MEDIA_PURPOSES},
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
                    self.assertTrue(report["browser_media_purpose_strings_verified"])
                    self.assertTrue(report["required_reason_entries_verified"])
                    self.assertEqual(report["signature_verified"], signed)

    def test_adhoc_codesign_seal_cannot_pass_as_distribution(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Example.app"
            app.mkdir()
            copy_privacy_manifest(app)
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": release.BUNDLE_ID,
                "CFBundleExecutable": "Example", "MinimumOSVersion": "17.0", "DTPlatformName": "iphoneos", "UIFileSharingEnabled": True, "LSSupportsOpeningDocumentsInPlace": True, **MEDIA_PURPOSES}))
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
                "CFBundleExecutable": "Example", "MinimumOSVersion": "17.0", "DTPlatformName": "iphoneos", "UIFileSharingEnabled": True, "LSSupportsOpeningDocumentsInPlace": True, **MEDIA_PURPOSES}))
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


class UIShardTests(unittest.TestCase):
    def test_repository_partition_and_workflow_choices_match(self):
        root = Path(__file__).resolve().parents[1]
        catalog = ios17.ui_inventory(root)
        tests = [t for s in catalog["shards"].values() for t in s["tests"]]
        self.assertEqual(len(tests), len(set(tests)))
        self.assertEqual(len(tests), catalog["non_live_test_count"])
        self.assertTrue(set(tests).isdisjoint(catalog["live_tests_excluded"]))
        for scope, shard in catalog["shards"].items():
            self.assertEqual(ios17.selected_ui_tests(catalog, scope), shard["tests"])
            self.assertEqual(ios17.TEST_SCOPES[scope], ["WoowAssistantUITests/" + c for c in shard["classes"]])
        self.assertEqual(ios17.selected_ui_tests(catalog, "core"), [])
        self.assertEqual(ios17.selected_ui_tests(catalog, "startup-smoke"), ios17.TEST_SCOPES["startup-smoke"])
        workflow = (root / ".github/workflows/release-ios.yml").read_text()
        options = re.search(r'ios17_test_scope:\s*\n.*?options: \[([^\]]+)\]', workflow, re.S).group(1)
        self.assertEqual([s.strip() for s in options.split(",")], list(ios17.TEST_SCOPES))
        self.assertIn("scripts/release_ios17.py --check-ui-inventory", workflow)
        self.assertIn('--expected-host-arch "$IOS17_HOST_ARCH"', workflow)
        self.assertIn("inputs.ios17_host_arch == 'x86_64'", workflow)

    def test_inventory_rejects_new_unowned_duplicate_live_and_stale_classes(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            target = root / "Tests/WoowAssistantUITests"
            target.mkdir(parents=True)
            for name in ["ExampleUITests", *sorted(ios17.LIVE_UI_CLASSES)]:
                (target / (name + ".swift")).write_text(
                    "final class " + name + ": XCTestCase {\nfunc testActual() {}\n}\n")
            mapping = {"ui-example": ["ExampleUITests"]}
            self.assertEqual(ios17.ui_inventory(root, mapping)["non_live_test_count"], 1)
            for invalid in [{}, {"ui-example": ["ExampleUITests", "ExampleUITests"]},
                            {**mapping, "ui-other": ["ExampleUITests"]},
                            {**mapping, "ui-other": ["MissingUITests"]},
                            {**mapping, "ui-other": ["LiveModelUITests"]}]:
                with self.subTest(mapping=invalid), self.assertRaises(release.ReleaseError):
                    ios17.ui_inventory(root, invalid)
            extra = target / "Nested/NewUITests.swift"
            extra.parent.mkdir()
            extra.write_text("final class NewUITests: XCTestCase { func testNew() {} }")
            with self.assertRaisesRegex(release.ReleaseError, "未涵蓋.*NewUITests"):
                ios17.ui_inventory(root, mapping)

    def test_new_method_is_included_and_non_test_strings_are_ignored(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            target = root / "Tests/WoowAssistantUITests"
            target.mkdir(parents=True)
            for name in ["ExampleUITests", *sorted(ios17.LIVE_UI_CLASSES)]:
                (target / (name + ".swift")).write_text(
                    'final class ' + name + ': XCTestCase {\nfunc testActual() {}\n}\n')
            source = target / "ExampleUITests.swift"
            original = source.read_text()
            source.write_text(original.replace("func testActual() {}", '''
                // func testComment() {}
                /* class FalseUITests: XCTestCase { func testComment() {} } */
                let html = #"""func testString() {}"""#
                func testActual() {}
                func testAdded() async throws {}
            '''))
            catalog = ios17.ui_inventory(root, {"ui-example": ["ExampleUITests"]})
            self.assertEqual(catalog["shards"]["ui-example"]["tests"], [
                "WoowAssistantUITests/ExampleUITests/testActual", "WoowAssistantUITests/ExampleUITests/testAdded"])
            for invalid in [original + 'extension ExampleUITests { func testExtra() {} }',
                            original.replace("func testActual() {}", "func testActual() {} func testActual() {}"),
                            original.replace("testActual()", "testActual(input: Int)")]:
                source.write_text(invalid)
                with self.assertRaises(release.ReleaseError):
                    ios17.ui_inventory(root, {"ui-example": ["ExampleUITests"]})

    def test_zero_exit_is_insufficient_with_skips_missing_repeated_or_wrong_cases(self):
        log, summary = synthetic_xctest_completion("ui-learning")
        # This shard now owns more than one class. Derive the expected complete
        # selection from source, never just one class found in the test log.
        catalog = ios17.ui_inventory(Path(__file__).resolve().parents[1])
        expected = ios17.selected_ui_tests(catalog, "ui-learning")
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "tests.log"
            path.write_bytes(log)
            self.assertTrue(ios17.test_completion(summary, path, expected, True)["verified"])
            for key in ("failedTests", "skippedTests", "expectedFailures"):
                wrong = dict(summary, **{key: 1})
                self.assertFalse(ios17.test_completion(wrong, path, expected, True)["verified"])
            for wrong in [{}, dict(summary, passedTests=0), dict(summary, totalTestCount=0),
                          dict(summary, result="Failed"), dict(summary, passedTests=True),
                          dict(summary, totalTestCount=len(expected) + 1, passedTests=len(expected) + 1)]:
                self.assertFalse(ios17.test_completion(wrong, path, expected, True)["verified"])
            lines = log.splitlines(keepends=True)
            for wrong_log in [b"", b"".join(lines[1:]), log + lines[0],
                              log.replace(b"passed", b"skipped", 1),
                              log.replace(b"BrowserLearningUITests", b"OtherUITests", 1)]:
                path.write_bytes(wrong_log)
                self.assertFalse(ios17.test_completion(summary, path, expected, True)["verified"])


class RuntimeTests(unittest.TestCase):
    DIAGNOSE_HELP = b"Usage: simctl diagnose [-l] [-q] [--udid=<udid>] [--output=<path>]\n"
    HOSTED_ENV = {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted", "RUNNER_OS": "macOS"}
    # Actual terminal record from run 42758764668 (iOS 17.0.1 / 21A342).
    MIGRATION_FAILURE = b"[2026-11-10 05:05:25 +0000] Status=3, isTerminal=YES, Elapsed=05:02.\n\tData Migration Failed\n\n"

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

    def test_xctest_outcome_preserves_scope_phase_and_cleanup(self):
        simulator = "12345678-1234-1234-1234-123456789ABC"
        def command(args, *unused, **kwargs):
            if "-version" in args: return b"Xcode 16.4"
            if "xcresulttool" in args: return json.dumps(summary).encode()
            if "-showBuildSettings" in args: return b"[]"
            if "create" in args: return simulator.encode()
            if "devices" in args:
                return json.dumps({"devices": {"test": [{"udid": simulator, "state": "Booted", "isAvailable": True}]}}).encode()
            return b""
        cases = [("all", 65, False, False), ("all", None, True, False), ("core", 0, False, False),
                 ("all", 0, False, False), ("startup-smoke", 0, False, False), ("all", 0, False, True),
                 ("ui-documents", 0, True, False), ("ui-memory", 0, False, True)]
        cases += [(scope, 0, False, False) for scope in [*ios17.UI_SHARDS, *ios17.DOCUMENT_SCOPES]]
        cases += [(scope, 0, True, False) for scope in ios17.DOCUMENT_SCOPES]
        cases += [(scope, 0, False, True) for scope in ios17.DOCUMENT_SCOPES]
        for scope, exit_code, timed_out, skipped in cases:
            with self.subTest(scope=scope, exit_code=exit_code, timed_out=timed_out, skipped=skipped), tempfile.TemporaryDirectory() as folder:
                output = Path(folder) / "result"
                log, summary = synthetic_xctest_completion(scope)
                if skipped:
                    summary.update(skippedTests=1, passedTests=summary["passedTests"] - 1)
                def child(args, **kwargs):
                    if args[0] == "xcodebuild":
                        self.assertEqual(args[args.index("-maximum-test-execution-time-allowance") + 1], "420" if scope in ("all", "ui-workspace") else "300")
                        self.assertEqual(kwargs["timeout"], 1800 if scope in ios17.UI_SHARDS or scope in ios17.DOCUMENT_SCOPES else 4800)
                        if scope == "core": self.assertIn("-only-testing:AssistantDomainTests", args)
                        elif scope == "startup-smoke":
                            self.assertIn("-only-testing:WoowAssistantUITests/WoowAssistantUITests/testEverySectionIsReachableAndPhoneControlIsExcluded", args)
                        elif scope in ios17.UI_SHARDS or scope in ios17.DOCUMENT_SCOPES:
                            self.assertEqual([arg for arg in args if arg.startswith("-only-testing:")],
                                             ["-only-testing:" + t for t in ios17.TEST_SCOPES[scope]])
                        else: self.assertFalse(any(arg.startswith("-only-testing:") for arg in args))
                        kwargs["stdout"].write(log)
                        if timed_out: raise subprocess.TimeoutExpired(args, kwargs["timeout"])
                        return subprocess.CompletedProcess(args, exit_code)
                    return subprocess.CompletedProcess(args, 0)
                with patch.object(ios17, "run", side_effect=command) as runner, \
                     patch.object(ios17, "boot_simulator"), \
                     patch.object(ios17, "prelaunch_test_daemon") as prelaunch, \
                     patch.object(ios17, "collect_boot_diagnostics") as diagnostic, \
                     patch.object(ios17, "ensure_runtime", return_value=self.payload()["runtimes"][0]), \
                     patch.object(ios17, "generate_project", return_value=output / "Project.xcodeproj"), \
                     patch.object(ios17, "verify_settings"), \
                     patch.object(ios17.subprocess, "run", side_effect=child), \
                     patch("builtins.print"):
                    if timed_out or exit_code or skipped:
                        with self.assertRaises(release.ReleaseError): ios17.execute(output, "17.0.1", False, scope)
                    else:
                        ios17.execute(output, "17.0.1", False, scope)
                    diagnostic.assert_not_called()
                    prelaunch.assert_not_called()  # Experimental prelaunch is off by default in every scope.
                report = json.loads((output / "report.json").read_text())
                succeeded = not timed_out and exit_code == 0 and not skipped
                self.assertEqual(report["test_scope"], scope)
                self.assertEqual(report["maximum_case_seconds"], 420 if scope in ("all", "ui-workspace") else 300)
                self.assertEqual(report["selected_tests_succeeded"], succeeded)
                self.assertEqual(report["runtime_tested"], succeeded and scope == "all")
                self.assertEqual(report["full_acceptance_succeeded"], succeeded and scope == "all")
                self.assertEqual(report["phase"], "passed" if succeeded else "verifying_test_completion" if skipped else "testing")
                self.assertEqual(report["phase_history"][-1]["phase"], report["phase"])
                self.assertEqual(report["test_timed_out"] if timed_out else report["test_exit_code"], True if timed_out else exit_code)
                self.assertTrue((output / "ui-test-inventory.json").is_file())
                self.assertEqual(report["live_ui_selected"], scope == "all")
                self.assertTrue(any(call.args[0] == ["xcrun", "simctl", "delete", simulator] for call in runner.call_args_list))
                self.assertFalse((output / "report.json.tmp").exists())

    def test_wrong_host_architecture_fails_before_any_tool_or_runtime_mutation(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "result"
            with patch.object(ios17.platform, "machine", return_value="x86_64"), \
                 patch.object(ios17, "run") as runner, \
                 patch.object(ios17, "ensure_runtime") as runtime, patch("builtins.print"):
                with self.assertRaisesRegex(release.ReleaseError, "主機架構"):
                    ios17.execute(output, "17.0.1", True, "startup-smoke", "arm64")
            runner.assert_not_called()
            runtime.assert_not_called()
            report = json.loads((output / "report.json").read_text())
            self.assertEqual(report["host_architecture"], "x86_64")
            self.assertEqual(report["expected_host_architecture"], "arm64")
            self.assertFalse(report["selected_tests_succeeded"])
            self.assertFalse(report["runtime_tested"])

    def test_inventory_and_cleanup_cannot_mask_boot_outcome(self):
        simulator = "12345678-1234-1234-1234-123456789ABC"
        cases = [(False, False, False, 0), (True, False, False, 0),
                 (True, True, False, 0), (False, True, False, 0),
                 (False, False, True, 0), (False, True, False, 65)]
        for boot_failed, cleanup_failed, invalid_inventory, test_exit in cases:
            with self.subTest(case=(boot_failed, cleanup_failed, invalid_inventory, test_exit)), tempfile.TemporaryDirectory() as folder:
                output = Path(folder) / "result"
                tested = []
                def command(args, *unused, **kwargs):
                    if "-version" in args: return b"Xcode 16.4"
                    if "xcresulttool" in args: return json.dumps(synthetic_xctest_completion("core")[1]).encode()
                    if "-showBuildSettings" in args: return b"[]"
                    if "create" in args: return simulator.encode()
                    if "bootstatus" in args and boot_failed:
                        raise release.ReleaseError("primary boot migration failure")
                    if "devices" in args:
                        # The 17.5 runner completed boot but its inventory hung.
                        if invalid_inventory: return b"not JSON"
                        raise release.ReleaseError("secondary inventory timeout")
                    if "delete" in args and cleanup_failed:
                        raise release.ReleaseError("secondary delete failure")
                    return b""
                def child(args, **kwargs):
                    if args[0] == "xcodebuild":
                        tested.append(args)
                        return subprocess.CompletedProcess(args, test_exit)
                    if "shutdown" in args and cleanup_failed:
                        raise subprocess.TimeoutExpired(args, kwargs["timeout"])
                    return subprocess.CompletedProcess(args, 0)
                with patch.object(ios17, "run", side_effect=command) as runner, \
                     patch.object(ios17, "boot_simulator", side_effect=release.ReleaseError("primary boot migration failure") if boot_failed else None), \
                     patch.object(ios17, "ensure_runtime", return_value=self.payload()["runtimes"][0]), \
                     patch.object(ios17, "generate_project", return_value=output / "Project.xcodeproj"), \
                     patch.object(ios17, "verify_settings"), \
                     patch.object(ios17.subprocess, "run", side_effect=child), patch("builtins.print"):
                    if boot_failed or cleanup_failed or test_exit:
                        expected = ("primary boot migration failure" if boot_failed else
                                    "XCTest 失敗" if test_exit else "secondary delete failure")
                        with self.assertRaisesRegex(release.ReleaseError, expected):
                            ios17.execute(output, "17.5", False, "core")
                    else:
                        ios17.execute(output, "17.5", False, "core")
                report = json.loads((output / "report.json").read_text())
                self.assertEqual(report["boot_succeeded"], not boot_failed)
                self.assertEqual(report["simulator_deleted"], not cleanup_failed)
                self.assertTrue(report["simulator_state_unavailable"])
                self.assertEqual(len(tested), 0 if boot_failed else 1)
                self.assertEqual(report["selected_tests_succeeded"], not boot_failed and test_exit == 0)
                if test_exit: self.assertEqual(report["test_exit_code"], test_exit)
                self.assertFalse(report["runtime_tested"])
                self.assertTrue(any(call.args[0] == ["xcrun", "simctl", "delete", simulator] for call in runner.call_args_list))

    def test_boot_terminal_failure_is_not_process_success(self):
        finished = b"[2026-11-10 05:16:08 +0000] Status=4294967295, isTerminal=YES, Elapsed=03:42.\n\tFinished\n"
        cases = [(self.MIGRATION_FAILURE, 0, True), (self.MIGRATION_FAILURE, 70, True),
                 (self.MIGRATION_FAILURE, "timeout", True), (finished, 0, False),
                 (finished, 70, True), (b"Device already booted\n", 0, False)]
        simulator = "12345678-1234-1234-1234-123456789ABC"
        for log, outcome, failed in cases:
            with self.subTest(outcome=outcome, log=log), tempfile.TemporaryDirectory() as folder:
                report = {}
                def child(args, **kwargs):
                    self.assertEqual(args, ["xcrun", "simctl", "bootstatus", simulator, "-b"])
                    self.assertEqual(kwargs["timeout"], 900)
                    kwargs["stdout"].write(log)
                    if outcome == "timeout": raise subprocess.TimeoutExpired(args, 900)
                    return subprocess.CompletedProcess(args, outcome)
                with patch.object(ios17.subprocess, "run", side_effect=child) as tool:
                    if failed:
                        expected = "逾時" if outcome == "timeout" else "退出碼 70" if outcome == 70 else "Data Migration Failed"
                        with self.assertRaisesRegex(release.ReleaseError, expected):
                            ios17.boot_simulator(Path(folder), simulator, report)
                    else:
                        ios17.boot_simulator(Path(folder), simulator, report)
                self.assertEqual(tool.call_count, 1)
                self.assertEqual(report["boot_exit_code"], None if outcome == "timeout" else outcome)
                self.assertEqual((Path(folder) / "simulator-boot.log").read_bytes(), log)
                if log == self.MIGRATION_FAILURE:
                    self.assertEqual(report["boot_terminal_status"], 3)
                    self.assertTrue(report["boot_data_migration_failed"])
                elif log == finished:
                    self.assertEqual(report["boot_terminal_status"], 4294967295)
                    self.assertFalse(report["boot_data_migration_failed"])

    def test_boot_diagnostics_require_hosted_scope_and_confirmed_flags(self):
        simulator = "12345678-1234-1234-1234-123456789ABC"
        for env in [{}, dict(self.HOSTED_ENV, RUNNER_ENVIRONMENT="self-hosted"),
                    dict(self.HOSTED_ENV, RUNNER_OS="Linux")]:
            with self.subTest(env=env), patch.dict(os.environ, env, clear=True), \
                 patch.object(ios17.subprocess, "run") as child:
                result = ios17.collect_boot_diagnostics(Path("unused"), simulator)
                self.assertEqual(result["status"], "skipped_not_ephemeral_hosted_macos")
                self.assertFalse(result["attempted"])
                child.assert_not_called()
        cases = [(self.DIAGNOSE_HELP.replace(flag, b"unsupported"), 0, False, "skipped_required_flags_unavailable")
                 for flag in [b"--udid", b"--output", b"-l", b"-q"]]
        cases += [(self.DIAGNOSE_HELP, 1, False, "help_failed"),
                  (self.DIAGNOSE_HELP, 0, True, "help_timed_out")]
        for help_text, exit_code, timed_out, expected in cases:
            with self.subTest(expected=expected, help_text=help_text), tempfile.TemporaryDirectory() as folder:
                def child(args, **kwargs):
                    self.assertEqual(args, ["xcrun", "simctl", "help", "diagnose"])
                    self.assertEqual(kwargs["timeout"], 10)
                    self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
                    kwargs["stdout"].write(help_text)
                    if timed_out: raise subprocess.TimeoutExpired(args, 10)
                    return subprocess.CompletedProcess(args, exit_code)
                with patch.dict(os.environ, self.HOSTED_ENV, clear=True), \
                     patch.object(ios17.subprocess, "run", side_effect=child) as tool:
                    result = ios17.collect_boot_diagnostics(Path(folder), simulator)
                self.assertEqual(result["status"], expected)
                self.assertFalse(result["attempted"])
                self.assertEqual(tool.call_count, 1)
                self.assertFalse((Path(folder) / "boot-diagnostics").exists())

    def test_boot_diagnostics_budget_includes_help_and_never_retries(self):
        simulator = "12345678-1234-1234-1234-123456789ABC"
        for elapsed in [7, 91]:
            with self.subTest(elapsed=elapsed), tempfile.TemporaryDirectory() as folder:
                output = Path(folder)
                def child(args, **kwargs):
                    if "help" in args:
                        kwargs["stdout"].write(self.DIAGNOSE_HELP)
                        return subprocess.CompletedProcess(args, 0)
                    self.assertEqual(args, ["xcrun", "simctl", "diagnose", "-l", "-q",
                        "--udid=" + simulator, "--output=" + str((output / "boot-diagnostics").resolve())])
                    self.assertEqual(kwargs["timeout"], 83)
                    self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
                    kwargs["stdout"].write(b"synthetic partial diagnosis\n")
                    raise subprocess.TimeoutExpired(args, kwargs["timeout"])
                with patch.dict(os.environ, self.HOSTED_ENV, clear=True), \
                     patch.object(ios17.time, "monotonic", side_effect=[100, 100 + elapsed]), \
                     patch.object(ios17.subprocess, "run", side_effect=child) as tool:
                    result = ios17.collect_boot_diagnostics(output, simulator)
                self.assertEqual(result["status"], "collection_timed_out" if elapsed == 7 else "skipped_budget_exhausted")
                self.assertEqual(result["attempted"], elapsed == 7)
                self.assertEqual(tool.call_count, 2 if elapsed == 7 else 1)
                if elapsed == 7:
                    self.assertEqual((output / "simctl-diagnose.log").read_bytes(), b"synthetic partial diagnosis\n")

    def test_diagnostics_before_cleanup_never_replace_primary_boot_failure(self):
        simulator = "12345678-1234-1234-1234-123456789ABC"
        primary = "iOS 17 Simulator 資料移轉失敗（Data Migration Failed）；未執行測試。"
        for outcome in [0, 70, "timeout", "io_error", "unexpected"]:
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as folder:
                output = Path(folder) / "result"
                events = []
                def command(args, *unused, **kwargs):
                    if "-version" in args: return b"Xcode 16.4"
                    if "-showBuildSettings" in args: return b"[]"
                    if "create" in args: return simulator.encode()
                    if "devices" in args:
                        events.append("inventory")
                        raise release.ReleaseError("secondary inventory failure")
                    if "delete" in args:
                        self.assertEqual(args[-1], simulator)
                        events.append("delete")
                        raise release.ReleaseError("secondary delete failure")
                    return b""
                def child(args, **kwargs):
                    if "bootstatus" in args:
                        events.append("boot")
                        kwargs["stdout"].write(self.MIGRATION_FAILURE)
                        return subprocess.CompletedProcess(args, 0)
                    if "help" in args:
                        events.append("help")
                        persisted = json.loads((output / "report.json").read_text())
                        self.assertEqual(persisted["boot_error"], primary)
                        self.assertEqual(persisted["boot_exit_code"], 0)
                        self.assertEqual(persisted["boot_terminal_status"], 3)
                        self.assertFalse(persisted["boot_succeeded"])
                        kwargs["stdout"].write(self.DIAGNOSE_HELP)
                        return subprocess.CompletedProcess(args, 0)
                    if "diagnose" in args:
                        events.append("diagnose")
                        self.assertIn("--udid=" + simulator, args)
                        self.assertLessEqual(kwargs["timeout"], 90)
                        if outcome == "timeout": raise subprocess.TimeoutExpired(args, kwargs["timeout"])
                        if outcome == "io_error": raise OSError("secondary diagnostic failure")
                        if outcome == "unexpected": raise RuntimeError("secondary unexpected failure")
                        return subprocess.CompletedProcess(args, outcome)
                    self.assertEqual(args, ["xcrun", "simctl", "shutdown", simulator])
                    events.append("shutdown")
                    raise subprocess.TimeoutExpired(args, kwargs["timeout"])
                with patch.dict(os.environ, self.HOSTED_ENV, clear=True), \
                     patch.object(ios17, "run", side_effect=command), \
                     patch.object(ios17, "ensure_runtime", return_value=self.payload()["runtimes"][0]), \
                     patch.object(ios17, "generate_project", return_value=output / "Project.xcodeproj"), \
                     patch.object(ios17, "verify_settings"), \
                     patch.object(ios17.subprocess, "run", side_effect=child), patch("builtins.print"):
                    with self.assertRaisesRegex(release.ReleaseError, "Data Migration Failed"):
                        ios17.execute(output, "17.0.1", False)
                self.assertEqual(events, ["boot", "help", "diagnose", "inventory", "shutdown", "delete"])
                report = json.loads((output / "report.json").read_text())
                expected = {0: "completed", 70: "failed", "timeout": "collection_timed_out",
                            "io_error": "collection_unavailable", "unexpected": "unexpected_diagnostic_error"}
                self.assertEqual(report["boot_diagnostics"]["status"], expected[outcome])
                self.assertEqual(report["boot_error"], primary)
                self.assertEqual(report["boot_exit_code"], 0)
                self.assertTrue(report["boot_data_migration_failed"])
                self.assertEqual(report["phase"], "booting")
                self.assertFalse(report["runtime_tested"])
                self.assertTrue(report["simulator_state_unavailable"])
                self.assertTrue(report["simulator_shutdown_incomplete"])
                self.assertFalse(report["simulator_deleted"])


class RuntimeFailureDiagnosticsTests(unittest.TestCase):
    SENTINEL = "SYNTHETIC_PRIVATE_DIAGNOSTIC_91"
    INVENTORY = ["xcrun", "simctl", "list", "runtimes", "--json"]

    def assert_safe(self, text, private_path):
        for forbidden in [self.SENTINEL, str(private_path), "import os", "subprocess.run", "command", "stdout", "stderr"]:
            self.assertNotIn(forbidden, text)

    def test_actual_timeout_and_nonzero_child_publish_only_closed_category(self):
        with tempfile.TemporaryDirectory(prefix="woow-private-child-") as directory:
            folder = Path(directory)
            for category, tail in [("timeout", "time.sleep(5)"), ("nonzeroExit", "sys.exit(7)")]:
                with self.subTest(category=category):
                    marker = folder / category
                    code = ("import os,sys,time; from pathlib import Path; "
                            "print(sys.argv[2], flush=True); print(os.environ['PRIVATE_TEST_VALUE'], file=sys.stderr, flush=True); "
                            "Path(sys.argv[1]).write_text('started'); " + tail)
                    output = io.StringIO()
                    with redirect_stdout(output), redirect_stderr(output), self.assertRaises(release.ReleaseToolError) as caught:
                        release.run([sys.executable, "-c", code, str(marker), self.SENTINEL], "固定測試操作",
                                    timeout=1, env={**os.environ, "PRIVATE_TEST_VALUE": self.SENTINEL})
                    self.assertEqual(marker.read_text(), "started")
                    self.assertEqual(caught.exception.category, category)
                    self.assertIsInstance(caught.exception, release.ReleaseError)
                    self.assertEqual(vars(caught.exception), {"category": category})
                    self.assert_safe(str(caught.exception) + output.getvalue(), folder)

    def test_actual_missing_executable_has_no_private_path(self):
        with tempfile.TemporaryDirectory(prefix="woow-private-launch-") as directory:
            missing = Path(directory) / self.SENTINEL
            with self.assertRaises(release.ReleaseToolError) as caught:
                release.run([str(missing)], "固定測試操作")
            self.assertEqual(caught.exception.category, "launchFailed")
            self.assert_safe(str(caught.exception), missing)

    def test_unknown_failure_category_is_not_published(self):
        with self.assertRaises(ValueError) as caught:
            release.ReleaseToolError("固定測試操作", self.SENTINEL)
        self.assertNotIn(self.SENTINEL, str(caught.exception))

    def exercise_report_failure(self, category):
        actual_run = subprocess.run
        with tempfile.TemporaryDirectory(prefix="woow-private-report-") as directory:
            folder = Path(directory); output = folder / "result"; marker = folder / "child-started"
            seen = []
            def child(args, **kwargs):
                seen.append(args)
                if args == ["xcodebuild", "-version"]:
                    return subprocess.CompletedProcess(args, 0, b"Xcode 16.4", b"")
                self.assertEqual(args, self.INVENTORY)  # Only the bounded inventory retry is permitted.
                self.assertEqual(kwargs["timeout"], 120)
                self.assertTrue(kwargs["capture_output"])
                if category == "timeout":
                    # The product still requests 120s; only this real synthetic
                    # child gets a 1s deadline so the local regression is bounded.
                    code = ("import sys,time; from pathlib import Path; "
                            "print(sys.argv[2], flush=True); print(sys.argv[2], file=sys.stderr, flush=True); "
                            "Path(sys.argv[1]).write_text('started'); time.sleep(5)")
                    return actual_run([sys.executable, "-c", code, str(marker), self.SENTINEL],
                                      **{**kwargs, "timeout": 1})
                if category == "launchFailed":
                    raise FileNotFoundError(str(folder / self.SENTINEL))
                return subprocess.CompletedProcess(args, 7, self.SENTINEL.encode(), self.SENTINEL.encode())
            captured = io.StringIO()
            with patch.object(release.subprocess, "run", side_effect=child), \
                 patch.object(ios17, "generate_project") as generate, \
                 patch.object(ios17, "boot_simulator") as boot, \
                 patch.object(ios17, "prelaunch_test_daemon") as prelaunch, \
                 patch.object(sys, "argv", ["release_ios17.py", "--os", "17.0.1", "--test-scope", "ui-workspace", "--output", str(output)]), \
                 redirect_stdout(captured), redirect_stderr(captured):
                self.assertEqual(ios17.main(), 1)
                generate.assert_not_called(); boot.assert_not_called(); prelaunch.assert_not_called()
            self.assertEqual(seen, [["xcodebuild", "-version"]] +
                             [self.INVENTORY] * (2 if category == "timeout" else 1))
            if category == "timeout": self.assertEqual(marker.read_text(), "started")
            report_text = (output / "report.json").read_text()
            report = json.loads(report_text)
            self.assert_safe(report_text + captured.getvalue(), folder)
            self.assertEqual(report["phase"], "checking_runtime")
            self.assertEqual([event["phase"] for event in report["phase_history"]], ["preflight", "checking_runtime"])
            self.assertFalse(report["runtime_tested"])
            self.assertFalse(report["selected_tests_succeeded"])
            self.assertFalse(report["full_acceptance_succeeded"])
            self.assertEqual(set(report["failure"]), {"category", "operation", "elapsed_seconds", "timeout_seconds", "attempts", "max_attempts"})
            self.assertEqual(report["failure"]["category"], category)
            self.assertEqual(report["failure"]["operation"], "simulator_runtime_inventory")
            self.assertEqual(report["failure"]["timeout_seconds"], 120)
            self.assertEqual(report["failure"]["attempts"], 2 if category == "timeout" else 1)
            self.assertEqual(report["failure"]["max_attempts"], 2)
            self.assertGreaterEqual(report["failure"]["elapsed_seconds"], 1 if category == "timeout" else 0)
            self.assertLess(report["failure"]["elapsed_seconds"], 10)
            self.assertEqual({p.name for p in output.iterdir()}, {"report.json", "ui-test-inventory.json"})

    def test_two_actual_timeouts_persist_safe_report_and_exit_one_without_test(self):
        self.exercise_report_failure("timeout")

    def test_launch_and_exit_failures_keep_distinct_categories_without_test_or_retry(self):
        for category in ["launchFailed", "nonzeroExit"]:
            with self.subTest(category=category): self.exercise_report_failure(category)

    def test_successful_inventory_keeps_default_bound_and_existing_metadata(self):
        payload = RuntimeTests().payload()
        payload["unrelated"] = self.SENTINEL
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            with patch.object(release.subprocess, "run", return_value=subprocess.CompletedProcess(
                    self.INVENTORY, 0, json.dumps(payload).encode(), self.SENTINEL.encode())) as child:
                self.assertEqual(ios17.inventory(output, "runtimes-before.json"), payload)
            child.assert_called_once()
            self.assertEqual(child.call_args.args[0], self.INVENTORY)
            self.assertEqual(child.call_args.kwargs["timeout"], 120)
            recorded = (output / "runtimes-before.json").read_text()
            self.assertNotIn(self.SENTINEL, recorded)
            self.assertEqual(json.loads(recorded)["runtimes"][0]["version"], "17.0.1")
            self.assertEqual({p.name for p in output.iterdir()}, {"runtimes-before.json"})

    def test_inventory_recovers_after_one_timeout_without_publishing_child_output(self):
        payload = RuntimeTests().payload()
        with tempfile.TemporaryDirectory(prefix="woow-private-inventory-retry-") as directory:
            output = Path(directory)
            calls = []
            def child(args, **kwargs):
                calls.append((args, kwargs["timeout"]))
                if len(calls) == 1:
                    raise subprocess.TimeoutExpired(args, kwargs["timeout"],
                                                    output=self.SENTINEL.encode(), stderr=self.SENTINEL.encode())
                return subprocess.CompletedProcess(args, 0, json.dumps(payload).encode(), b"")
            with patch.object(release.subprocess, "run", side_effect=child):
                self.assertEqual(ios17.inventory(output, "runtimes-before.json"), payload)
            self.assertEqual(calls, [(self.INVENTORY, 120), (self.INVENTORY, 120)])
            recorded = (output / "runtimes-before.json").read_text()
            self.assertNotIn(self.SENTINEL, recorded)
            self.assertEqual(json.loads(recorded)["runtimes"][0]["version"], "17.0.1")


if __name__ == "__main__":
    unittest.main()
