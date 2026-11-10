import json
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


METHODS = ["WoowAssistantUITests/SkillExecutionUITests/testSyntheticOne",
           "WoowAssistantUITests/SkillExecutionUITests/testSyntheticTwo"]
SIMULATOR = "12345678-1234-1234-1234-123456789ABC"


def event(method, outcome):
    _, cls, name = method.split("/")
    suffix = "." if outcome == "started" else " (1.000 seconds)."
    return "Test Case '-[WoowAssistantUITests.%s %s]' %s%s\n" % (cls, name, outcome, suffix)


class ObservedEventsTests(unittest.TestCase):
    def observe(self, text):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "tests.log"
            path.write_text(text)
            return ios17.observed_ui_events(path, METHODS)

    def test_completed_failure_is_diagnostic_and_never_acceptance(self):
        text = event(METHODS[0], "started") + event(METHODS[0], "passed")
        text += event(METHODS[1], "started") + event(METHODS[1], "failed")
        result = self.observe(text + "private assertion body must not be copied\n")
        self.assertTrue(result["all_expected_completed_once"])
        self.assertFalse(result["acceptance_evidence"])
        self.assertEqual(result["counts"], {"starts": 2, "passed": 1, "failed": 1, "skipped": 0})
        self.assertNotIn("private assertion", json.dumps(result))

    def test_missing_duplicate_skipped_and_unexpected_events_remain_distinct(self):
        self.assertFalse(self.observe(event(METHODS[0], "started"))["all_expected_completed_once"])
        complete = "".join(event(m, "started") + event(m, "passed") for m in METHODS)
        self.assertFalse(self.observe(complete + event(METHODS[0], "passed"))["all_expected_completed_once"])
        self.assertFalse(self.observe(complete + event(METHODS[0], "started"))["all_expected_completed_once"])
        unknown = event("WoowAssistantUITests/UnknownTests/testPrivateLabel", "started")
        result = self.observe(complete + unknown)
        self.assertFalse(result["all_expected_completed_once"])
        self.assertEqual(result["unexpected_events"], 1)
        self.assertNotIn("testPrivateLabel", json.dumps(result))
        skipped = self.observe(complete.replace("passed", "skipped"))
        self.assertEqual(skipped["counts"]["skipped"], 2)
        self.assertFalse(skipped["acceptance_evidence"])

    def test_non_event_lines_and_oversize_log_do_not_claim_completions(self):
        result = self.observe("synthetic payload " + event(METHODS[0], "passed"))
        self.assertEqual(result["counts"]["passed"], 0)
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "tests.log"
            with path.open("wb") as log:
                log.truncate(16 * 1024 * 1024 + 1)
            self.assertEqual(ios17.observed_ui_events(path, METHODS),
                             {"status": "log_size_limit", "acceptance_evidence": False})


class FinalizationTests(unittest.TestCase):
    def exercise(self, *, bounded, identity=True, completed=True, timeout=True):
        calls = []
        text = "".join(event(m, "started") + event(m, "failed" if i else "passed")
                       for i, m in enumerate(METHODS)) if completed else ""

        def command(args, *unused, **kwargs):
            if "-version" in args:
                return b"Xcode 16.4"
            if "-showBuildSettings" in args:
                return b"[]"
            if "create" in args:
                return SIMULATOR.encode()
            if "devices" in args:
                return b'{"devices": {}}'
            return b""

        def xcode(args, log, budget, observer=None):
            calls.append((args, budget))
            log.write(text.encode())
            if observer:
                observer.report["status"] = "stopped"
            if timeout:
                raise subprocess.TimeoutExpired(args, budget)
            return subprocess.CompletedProcess(args, 65)

        def child(args, **kwargs):
            if args[0] == "xcodebuild":
                return xcode(args, kwargs["stdout"], kwargs["timeout"])
            self.assertEqual(args[:3], ["xcrun", "simctl", "shutdown"])
            return subprocess.CompletedProcess(args, 0)

        class Observer:
            def __init__(self, *args):
                self.report = {"status": "observing"}

        with tempfile.TemporaryDirectory() as folder, ExitStack() as stack:
            output = Path(folder) / "result"
            for owner, name, kwargs in [
                (ios17, "run", {"side_effect": command}),
                (ios17, "boot_simulator", {}),
                (ios17, "prelaunch_test_daemon", {}),
                (ios17, "ensure_runtime", {"return_value": {"version": "17.0.1", "identifier": "synthetic"}}),
                (ios17, "generate_project", {"return_value": output / "Project.xcodeproj"}),
                (ios17, "verify_settings", {}),
                (ios17, "ui_inventory", {"return_value": {"inventory_sha256": "synthetic", "live_tests_excluded": []}}),
                (ios17, "selected_ui_tests", {"return_value": METHODS}),
                (ios17.subprocess, "run", {"side_effect": child}),
                (watchdog, "validate_gate", {}),
                (watchdog, "runtime_root", {}),
                (watchdog, "PublicProcessIdentity", {}),
                (watchdog, "OwnedProcesses", {} if identity else {"side_effect": ValueError("unavailable")}),
                (watchdog, "Watchdog", {"side_effect": Observer}),
                (watchdog, "run_observed", {"side_effect": xcode}),
            ]:
                stack.enter_context(patch.object(owner, name, **kwargs))
            stack.enter_context(patch("builtins.print"))
            with self.assertRaises(ReleaseError):
                ios17.execute(output, "17.0.1", False, "ui-documents", prelaunch_daemon=True,
                              sample_bootstrap=True, bounded_test_diagnostics=bounded)
            report = json.loads((output / "report.json").read_text())
        self.assertEqual(len(calls), 1)
        args, budget = calls[0]
        self.assertEqual(budget, 1800)
        self.assertEqual(args[args.index("-maximum-test-execution-time-allowance") + 1], "300")
        self.assertEqual([a for a in args if a.startswith("-only-testing:")],
                         ["-only-testing:" + t for t in ios17.TEST_SCOPES["ui-documents"]])
        self.assertFalse(report["selected_tests_succeeded"])
        self.assertFalse(report["full_acceptance_succeeded"])
        self.assertTrue(report["simulator_deleted"])
        return report, args

    def test_timeout_after_all_methods_keeps_failure_counts_and_stopped_sampler(self):
        report, args = self.exercise(bounded=True)
        self.assertEqual(report["timeout_phase"], "after_selected_ui_methods")
        self.assertEqual(report["observed_ui_events"]["counts"]["failed"], 1)
        self.assertEqual(report["bootstrap_sampling_status"], "stopped")
        self.assertEqual(args[args.index("-collect-test-diagnostics") + 1], "never")
        self.assertEqual(report["verbose_failure_diagnostics"], "disabled_with_bounded_sampling")

    def test_default_and_identity_failure_keep_xcode_diagnostics(self):
        for options in ({"bounded": False}, {"bounded": True, "identity": False}):
            with self.subTest(options=options):
                report, args = self.exercise(**options)
                self.assertNotIn("-collect-test-diagnostics", args)
                self.assertEqual(report["verbose_failure_diagnostics"], "xcode_default")

    def test_no_method_timeout_and_nonzero_exit_never_gain_acceptance(self):
        report, _ = self.exercise(bounded=True, completed=False)
        self.assertEqual(report["timeout_phase"], "before_selected_ui_methods")
        report, _ = self.exercise(bounded=True, timeout=False)
        self.assertEqual(report["test_exit_code"], 65)
        self.assertNotIn("timeout_phase", report)

    def test_explicit_option_requires_existing_hosted_nonlive_sampling_gate(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "result"
            for sample in (False, True):
                with self.subTest(sample=sample), patch.dict(ios17.os.environ, {}, clear=True):
                    with self.assertRaises(ReleaseError):
                        ios17.execute(output, "17.0.1", False, "ui-documents", prelaunch_daemon=True,
                                      sample_bootstrap=sample, bounded_test_diagnostics=True)
                    self.assertFalse(output.exists())

    def test_cli_and_workflow_default_off_separate_the_comparison(self):
        for flags, enabled in (([], False), (["--bounded-test-diagnostics"], True)):
            with patch.object(sys, "argv", ["release_ios17.py", *flags]), patch.object(ios17, "execute") as execute:
                self.assertEqual(ios17.main(), 0)
                self.assertEqual(execute.call_args.kwargs["bounded_test_diagnostics"], enabled)
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/release-ios.yml").read_text()
        option = workflow.split("      ios17_bounded_test_diagnostics:\n", 1)[1].split("\npermissions:", 1)[0]
        self.assertIn("default: false", option)
        group = next(line for line in workflow.splitlines() if line.strip().startswith("group:"))
        self.assertIn("inputs.ios17_bounded_test_diagnostics", group)


if __name__ == "__main__":
    unittest.main()
