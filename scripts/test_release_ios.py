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
            if "-showBuildSettings" in args: return b"[]"
            if "create" in args: return simulator.encode()
            if "devices" in args:
                return json.dumps({"devices": {"test": [{"udid": simulator, "state": "Booted", "isAvailable": True}]}}).encode()
            return b""
        for scope, exit_code, timed_out in [("all", 65, False), ("all", None, True), ("core", 0, False), ("all", 0, False)]:
            with self.subTest(scope=scope, exit_code=exit_code, timed_out=timed_out), tempfile.TemporaryDirectory() as folder:
                output = Path(folder) / "result"
                def child(args, **kwargs):
                    if args[0] == "xcodebuild":
                        if scope == "core": self.assertIn("-only-testing:AssistantDomainTests", args)
                        else: self.assertFalse(any(arg.startswith("-only-testing:") for arg in args))
                        if timed_out: raise subprocess.TimeoutExpired(args, kwargs["timeout"])
                        return subprocess.CompletedProcess(args, exit_code)
                    return subprocess.CompletedProcess(args, 0)
                with patch.object(ios17, "run", side_effect=command) as runner, \
                     patch.object(ios17, "boot_simulator"), \
                     patch.object(ios17, "collect_boot_diagnostics") as diagnostic, \
                     patch.object(ios17, "ensure_runtime", return_value=self.payload()["runtimes"][0]), \
                     patch.object(ios17, "generate_project", return_value=output / "Project.xcodeproj"), \
                     patch.object(ios17, "verify_settings"), \
                     patch.object(ios17.subprocess, "run", side_effect=child), \
                     patch("builtins.print"):
                    if timed_out or exit_code:
                        with self.assertRaises(release.ReleaseError): ios17.execute(output, "17.0.1", False, scope)
                    else:
                        ios17.execute(output, "17.0.1", False, scope)
                    diagnostic.assert_not_called()
                report = json.loads((output / "report.json").read_text())
                succeeded = not timed_out and exit_code == 0
                self.assertEqual(report["test_scope"], scope)
                self.assertEqual(report["selected_tests_succeeded"], succeeded)
                self.assertEqual(report["runtime_tested"], succeeded and scope == "all")
                self.assertEqual(report["phase"], "passed" if succeeded else "testing")
                self.assertEqual(report["phase_history"][-1]["phase"], report["phase"])
                self.assertEqual(report["test_timed_out"] if timed_out else report["test_exit_code"], True if timed_out else exit_code)
                self.assertTrue(any(call.args[0] == ["xcrun", "simctl", "delete", simulator] for call in runner.call_args_list))
                self.assertFalse((output / "report.json.tmp").exists())

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


if __name__ == "__main__":
    unittest.main()
