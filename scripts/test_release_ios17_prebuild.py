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
    def test_actual_workflow_prebuild_gate_accepts_pair_and_retains_hosted_fixture_requirements(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/release-ios.yml").read_text()
        section = workflow.split('if [ "$IOS17_BUILD_BEFORE_BOOT" = true ]; then', 1)[1]
        condition = next(line.strip() for line in section.splitlines() if line.strip().startswith("if "))
        self.assertTrue(condition.endswith("; then"))
        command = condition + " exit 1; else exit 0; fi"
        valid = {"VALIDATION_MODE": "ios17-hosted", "IOS17_TEST_SCOPE": "pdf-assembly-multi",
                 "IOS17_SAMPLE_BOOTSTRAP": "true", "IOS17_PRELAUNCH": "true"}
        cases = [(dict(valid, IOS17_TEST_SCOPE=scope), 0) for scope in
                 ("startup-smoke", "pdf-assembly", "pdf-assembly-copy", "pdf-assembly-multi", "pdf-pair-coordinated",
                  "documents-read", "documents-output", "documents-chat", *ios17.UI_SHARDS)]
        cases += [(dict(valid, **changed), 1) for changed in
                  ({"VALIDATION_MODE": "ios17-self-hosted"}, {"IOS17_SAMPLE_BOOTSTRAP": "false"},
                   {"IOS17_PRELAUNCH": "false"}, {"IOS17_TEST_SCOPE": "core"},
                   {"IOS17_TEST_SCOPE": "pdf-assembly-uikit"}, {"IOS17_TEST_SCOPE": "live-model"})]
        for environment, expected in cases:
            with self.subTest(environment=environment):
                result = subprocess.run(["/bin/bash", "-c", command], env=environment, capture_output=True)
                self.assertEqual(result.returncode, expected, result.stderr.decode())

    def exercise(self, *, enabled=True, build_exit=0, manifest_kind="valid", test_exit=0, summary_pass=True,
                 scope="startup-smoke"):
        methods = ios17.selected_ui_tests(ios17.ui_inventory(Path(__file__).resolve().parents[1]), scope)
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

    def test_fixture_ui_shards_and_pdf_followups_keep_selection_budget_and_result_gates(self):
        for scope in ("pdf-assembly", "pdf-assembly-copy", "pdf-assembly-multi", "pdf-pair-coordinated", "documents-read", "documents-output", "documents-chat", *ios17.UI_SHARDS):
            with self.subTest(scope=scope):
                events, commands, report = self.exercise(scope=scope)
                self.assertLess(events.index("build"), events.index("boot"))
                command = next(args for args, _ in commands if "test-without-building" in args)
                self.assertEqual([x for x in command if x.startswith("-only-testing:")],
                                 ["-only-testing:" + method for method in ios17.TEST_SCOPES[scope]])
                expected_budget = 1800 if scope in ios17.DOCUMENT_SCOPES or scope in ios17.UI_SHARDS else 4800
                self.assertEqual(report["build_test_timeout_seconds"], expected_budget)
                self.assertLess(report["remaining_test_timeout_seconds"], expected_budget)
                self.assertTrue(report["selected_tests_succeeded"])
                self.assertFalse(report["full_acceptance_succeeded"])
                self.exercise(scope=scope, summary_pass=False)

    def test_pair_focus_keeps_one_exact_method_and_existing_case_and_combined_budgets(self):
        expected = "WoowAssistantUITests/SkillPDFAssemblyMultiFileUITests/testUserChosenCopyAddsTwoDistinctPDFsAndInterleavesApprovedPages"
        for enabled in (False, True):
            with self.subTest(prebuild=enabled):
                events, commands, report = self.exercise(scope="pdf-assembly-multi", enabled=enabled)
                test, budget = next(row for row in commands if "test-without-building" in row[0] or "test" in row[0])
                self.assertEqual([arg for arg in test if arg.startswith("-only-testing:")], ["-only-testing:" + expected])
                self.assertEqual(report["expected_ui_tests"], [expected])
                self.assertEqual(report["maximum_case_seconds"], 300)
                self.assertEqual(report["build_test_timeout_seconds"], 4800)
                self.assertAlmostEqual(budget + report.get("prebuild_elapsed_seconds", 0), 4800, places=2)
                self.assertEqual(events.count("test"), 1)
                self.assertEqual(events.count("build"), int(enabled))
                self.assertEqual(events[-2:], ["shutdown", "delete"])

    def test_pair_prebuild_requires_both_flags_and_does_not_enable_other_pdf_focus(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(watchdog, "validate_gate") as gate, \
                patch.object(ios17, "run") as command:
            output = Path(folder) / "result"
            for scope, prelaunch, sample in (("pdf-assembly-multi", False, False),
                                             ("pdf-assembly-multi", True, False),
                                             ("pdf-assembly-multi", False, True),
                                             ("pdf-assembly-uikit", True, True)):
                with self.subTest(scope=scope, prelaunch=prelaunch, sample=sample), self.assertRaises(ReleaseError):
                    ios17.execute(output, "17.0.1", False, scope, prelaunch_daemon=prelaunch,
                                  sample_bootstrap=sample, build_before_boot=True)
                self.assertFalse(output.exists())
            gate.assert_not_called()
            command.assert_not_called()

    def test_directory_candidate_keeps_exact_method_and_original_budgets(self):
        scope = "pdf-pair-coordinated"
        expected = "WoowAssistantUITests/SkillPDFAssemblyMultiFileUITests/testDirectoryCoordinatedFixtureCopyAddsTwoDistinctPDFsAndInterleavesApprovedPages"
        for enabled in (False, True):
            with self.subTest(prebuild=enabled):
                events, commands, report = self.exercise(scope=scope, enabled=enabled)
                test, budget = next(row for row in commands if "test-without-building" in row[0] or "test" in row[0])
                self.assertEqual([arg for arg in test if arg.startswith("-only-testing:")], ["-only-testing:" + expected])
                self.assertEqual(report["expected_ui_tests"], [expected])
                self.assertEqual(report["maximum_case_seconds"], 300)
                self.assertEqual(report["build_test_timeout_seconds"], 4800)
                self.assertAlmostEqual(budget + report.get("prebuild_elapsed_seconds", 0), 4800, places=2)
                self.assertEqual(events.count("test"), 1)
                self.assertEqual(events.count("build"), int(enabled))
        with tempfile.TemporaryDirectory() as folder, patch.object(watchdog, "validate_gate") as gate, \
                patch.object(ios17, "run") as command:
            output = Path(folder) / "result"
            for prelaunch, sample in ((False, False), (True, False), (False, True)):
                with self.subTest(prelaunch=prelaunch, sample=sample), self.assertRaises(ReleaseError):
                    ios17.execute(output, "17.0.1", False, scope, prelaunch_daemon=prelaunch,
                                  sample_bootstrap=sample, build_before_boot=True)
                self.assertFalse(output.exists())
            gate.assert_not_called()
            command.assert_not_called()

    def test_opt_in_is_hosted_sampled_fixture_only_and_no_invalid_setup_is_created(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(ios17.os.environ, {}, clear=True):
            output = Path(folder) / "result"
            for scope, sample in [("all", True), ("ui-documents", True), ("startup-smoke", False), ("startup-smoke", True),
                                  ("pdf-assembly", True), ("pdf-assembly-copy", True), ("pdf-assembly-multi", True), ("pdf-pair-coordinated", True),
                                  ("documents-read", True), ("documents-output", True), ("documents-chat", True), ("core", True),
                                  *((scope, True) for scope in ios17.UI_SHARDS)]:
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
