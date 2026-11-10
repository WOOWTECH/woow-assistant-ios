import hashlib
import json
import plistlib
from contextlib import ExitStack
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import ios17_bootstrap_watchdog as watchdog
import release_ios17 as ios17
from release_ios import ReleaseError


SIMULATOR = "12345678-1234-1234-1234-123456789ABC"
METHOD = "WoowAssistantUITests/WoowAssistantUITests/testEverySectionIsReachableAndPhoneControlIsExcluded"


class PrebuildTests(unittest.TestCase):
    def exercise(self, *, enabled=True, build_exit=0, manifest_kind="valid", test_exit=0, summary_pass=True,
                 scope="startup-smoke"):
        methods = ios17.TEST_SCOPES[scope]
        events, commands = [], []
        summary = {"result": "Passed" if summary_pass else "Failed", "totalTestCount": len(methods), "passedTests": len(methods) - int(not summary_pass),
                   "failedTests": int(not summary_pass), "skippedTests": 0, "expectedFailures": 0}

        def command(args, *unused, **kwargs):
            if "-version" in args:
                return b"Xcode 16.4"
            if "-showBuildSettings" in args:
                return b"[]"
            if "create" in args:
                events.append("create")
                return SIMULATOR.encode()
            if "devices" in args:
                return b'{"devices": {}}'
            if "delete" in args:
                events.append("delete")
            if "summary" in args:
                return json.dumps(summary).encode()
            return b""

        def child(args, **kwargs):
            commands.append((args, kwargs.get("timeout")))
            if "build-for-testing" in args:
                events.append("build")
                products = output / "DerivedData/Build/Products"
                products.mkdir(parents=True)
                manifest = products / "WoowAssistant.xctestrun"
                if manifest_kind != "missing":
                    manifest.write_bytes(plistlib.dumps({"TestConfigurations": []})
                                         if manifest_kind != "invalid" else b"invalid")
                if manifest_kind == "duplicate":
                    (products / "Old.xctestrun").write_bytes(manifest.read_bytes())
                if manifest_kind == "symlink":
                    elsewhere = output / "other.xctestrun"
                    manifest.rename(elsewhere)
                    manifest.symlink_to(elsewhere)
                if build_exit == "timeout":
                    raise subprocess.TimeoutExpired(args, kwargs["timeout"])
                return subprocess.CompletedProcess(args, build_exit)
            self.assertEqual(args[:3], ["xcrun", "simctl", "shutdown"])
            events.append("shutdown")
            return subprocess.CompletedProcess(args, 0)

        def test(args, log, budget, observer):
            events.append("test")
            commands.append((args, budget))
            for method in methods:
                _, cls, name = method.split("/")
                log.write(("Test Case '-[WoowAssistantUITests.%s %s]' started.\n"
                           "Test Case '-[WoowAssistantUITests.%s %s]' passed (1.000 seconds).\n"
                           % (cls, name, cls, name)).encode())
            return subprocess.CompletedProcess(args, test_exit)

        class Observer:
            def __init__(self, *args):
                self.report = {"status": "stopped"}

        with tempfile.TemporaryDirectory() as folder, ExitStack() as stack:
            output = Path(folder) / "result"
            for owner, name, values in [
                (ios17, "run", {"side_effect": command}),
                (ios17, "boot_simulator", {"side_effect": lambda *args: events.append("boot")}),
                (ios17, "prelaunch_test_daemon", {"side_effect": lambda *args: events.append("prelaunch")}),
                (ios17, "ensure_runtime", {"return_value": {"version": "17.0.1", "identifier": "synthetic"}}),
                (ios17, "generate_project", {"return_value": output / "Project.xcodeproj"}),
                (ios17, "verify_settings", {}),
                (ios17, "ui_inventory", {"return_value": {"inventory_sha256": "synthetic", "live_tests_excluded": []}}),
                (ios17, "selected_ui_tests", {"return_value": methods}),
                (ios17.subprocess, "run", {"side_effect": child}),
                (watchdog, "validate_gate", {}), (watchdog, "runtime_root", {}),
                (watchdog, "PublicProcessIdentity", {}), (watchdog, "OwnedProcesses", {}),
                (watchdog, "Watchdog", {"side_effect": Observer}),
                (watchdog, "run_observed", {"side_effect": test}),
            ]:
                stack.enter_context(patch.object(owner, name, **values))
            stack.enter_context(patch("builtins.print"))
            failure = build_exit != 0 or manifest_kind != "valid" or test_exit != 0 or not summary_pass
            if failure:
                with self.assertRaises(ReleaseError):
                    ios17.execute(output, "17.0.1", False, scope, prelaunch_daemon=True,
                                  sample_bootstrap=True, build_before_boot=enabled)
            else:
                ios17.execute(output, "17.0.1", False, scope, prelaunch_daemon=True,
                              sample_bootstrap=True, build_before_boot=enabled)
            report = json.loads((output / "report.json").read_text())
            if enabled and not failure:
                receipt = report["prebuilt_xctestrun"]
                self.assertEqual(receipt["sha256"], hashlib.sha256((output / receipt["path"]).read_bytes()).hexdigest())
        return events, commands, report

    def test_one_build_precedes_create_boot_and_single_test_of_exact_products(self):
        events, commands, report = self.exercise()
        self.assertEqual(events, ["build", "create", "boot", "prelaunch", "test", "shutdown", "delete"])
        build, test = [row for row in commands if row[0][0] == "xcodebuild"]
        self.assertEqual(build[1], 4800)
        self.assertLess(test[1], build[1])
        self.assertAlmostEqual(test[1] + report["prebuild_elapsed_seconds"], 4800, places=2)
        self.assertIn("test-without-building", test[0])
        self.assertNotIn("test", test[0])
        self.assertIn("-xctestrun", test[0])
        self.assertNotIn("-project", test[0])
        self.assertEqual([x for x in test[0] if x.startswith("-only-testing:")], ["-only-testing:" + METHOD])
        self.assertEqual(test[0][test[0].index("-maximum-test-execution-time-allowance") + 1], "300")
        self.assertTrue(report["selected_tests_succeeded"])
        self.assertFalse(report["runtime_tested"])
        self.assertFalse(report["full_acceptance_succeeded"])

    def test_default_flow_still_builds_and_tests_after_boot_once(self):
        events, commands, report = self.exercise(enabled=False)
        self.assertEqual(events, ["create", "boot", "prelaunch", "test", "shutdown", "delete"])
        command, budget = next(row for row in commands if row[0][0] == "xcodebuild")
        self.assertIn("test", command)
        self.assertNotIn("-xctestrun", command)
        self.assertEqual(budget, 4800)
        self.assertNotIn("prebuilt_xctestrun", report)

    def test_bad_or_timed_out_build_never_creates_boots_or_runs_a_simulator(self):
        for options in [{"build_exit": 65}, {"build_exit": "timeout"},
                        *({"manifest_kind": kind} for kind in ["missing", "invalid", "duplicate", "symlink"])]:
            with self.subTest(options=options):
                events, _, report = self.exercise(**options)
                self.assertEqual(events, ["build"])
                self.assertFalse(report["selected_tests_succeeded"])
                self.assertNotIn("simulator_deleted", report)

    def test_nonzero_test_or_failed_summary_remains_failure_and_cleans_owned_device(self):
        for options in ({"test_exit": 65}, {"summary_pass": False}):
            with self.subTest(options=options):
                events, _, report = self.exercise(**options)
                self.assertEqual(events[-2:], ["shutdown", "delete"])
                self.assertFalse(report["selected_tests_succeeded"])

    def test_successful_build_cannot_reset_an_exhausted_combined_budget(self):
        with tempfile.TemporaryDirectory() as folder, \
                patch.object(ios17.time, "monotonic", side_effect=[0, 4801]), \
                patch.object(ios17.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as child:
            report = {"build_test_timeout_seconds": 4800, "host_architecture": "arm64"}
            with self.assertRaises(ReleaseError):
                ios17.build_before_simulator(["xcodebuild"], Path(folder), report)
            self.assertEqual(child.call_count, 1)
            self.assertEqual(report["remaining_test_timeout_seconds"], 0)
            self.assertEqual(report["prebuild_exit_code"], 0)

    def test_pdf_followups_keep_exact_selection_and_result_gates(self):
        for scope in ("pdf-assembly", "pdf-assembly-copy", "documents-read", "documents-output"):
            with self.subTest(scope=scope):
                events, commands, report = self.exercise(scope=scope)
                self.assertLess(events.index("build"), events.index("boot"))
                command = next(args for args, _ in commands if "test-without-building" in args)
                self.assertEqual([x for x in command if x.startswith("-only-testing:")],
                                 ["-only-testing:" + method for method in ios17.TEST_SCOPES[scope]])
                expected_budget = 1800 if scope in ios17.DOCUMENT_SCOPES else 4800
                self.assertEqual(report["build_test_timeout_seconds"], expected_budget)
                self.assertLess(report["remaining_test_timeout_seconds"], expected_budget)
                self.assertTrue(report["selected_tests_succeeded"])
                self.assertFalse(report["full_acceptance_succeeded"])
                self.exercise(scope=scope, summary_pass=False)

    def test_opt_in_is_hosted_sampled_focused_only_and_no_invalid_setup_is_created(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(ios17.os.environ, {}, clear=True):
            output = Path(folder) / "result"
            for scope, sample in [("all", True), ("ui-documents", True), ("startup-smoke", False), ("startup-smoke", True),
                                  ("pdf-assembly", True), ("pdf-assembly-copy", True),
                                  ("documents-read", True), ("documents-output", True)]:
                with self.subTest(scope=scope, sample=sample), self.assertRaises(ReleaseError):
                    ios17.execute(output, "17.0.1", False, scope, prelaunch_daemon=True,
                                  sample_bootstrap=sample, build_before_boot=True)
                self.assertFalse(output.exists())
        for flags, expected in (([], False), (["--build-before-boot"], True)):
            with patch.object(sys, "argv", ["release_ios17.py", *flags]), patch.object(ios17, "execute") as execute:
                self.assertEqual(ios17.main(), 0)
                self.assertEqual(execute.call_args.kwargs["build_before_boot"], expected)


if __name__ == "__main__":
    unittest.main()
