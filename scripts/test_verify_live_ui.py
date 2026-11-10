"""Private-result guards: real source inventory, synthetic xcresult metadata."""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import verify_live_ui as verifier


class LiveUIVerificationTests(unittest.TestCase):
    CLASS = "WoowAssistantUITests/LiveExampleUITests"
    OTHER = "WoowAssistantUITests/LiveOtherUITests"
    METHODS = [CLASS + "/testFirst", CLASS + "/testSecond", OTHER + "/testThird"]
    PRIVATE = "synthetic-private-value-must-not-be-printed"

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.bundle = Path(self.folder.name) / "Private.xcresult"
        self.bundle.mkdir()
        self.catalog = {"live_tests_excluded": self.METHODS}

    def summary(self, **changes):
        result = {"result": "Passed", "totalTestCount": 2, "passedTests": 2,
                  "failedTests": 0, "skippedTests": 0, "expectedFailures": 0,
                  "testFailures": [], "devicesAndConfigurations": [
                      {"passedTests": 2, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}]}
        result.update(changes)
        return result

    def verify_payload(self, payload, selectors=None):
        with patch.object(verifier, "ui_inventory", return_value=self.catalog), \
             patch.object(verifier.subprocess, "run", return_value=subprocess.CompletedProcess(
                 [], 0, json.dumps(payload).encode())):
            return verifier.verify(self.bundle, selectors or [self.CLASS], environment={})

    def test_real_repository_inventory_resolves_live_classes_and_exact_methods(self):
        catalog = verifier.ui_inventory(verifier.ROOT)
        methods = catalog["live_tests_excluded"]
        classes = sorted({m.rsplit("/", 1)[0] for m in methods})
        self.assertGreater(len(methods), 0)
        self.assertEqual(verifier.expected_tests(verifier.ROOT, classes), methods)
        for method in methods:
            self.assertEqual(verifier.expected_tests(verifier.ROOT, [method]), [method])

    def test_disjoint_class_and_method_selectors_form_source_count(self):
        with patch.object(verifier, "ui_inventory", return_value=self.catalog):
            self.assertEqual(verifier.expected_tests(verifier.ROOT, [self.CLASS]), self.METHODS[:2])
            self.assertEqual(verifier.expected_tests(verifier.ROOT, [self.CLASS, self.METHODS[2]]), self.METHODS)

    def test_unknown_non_live_partial_glob_duplicate_or_overlapping_selectors_fail_before_tool(self):
        invalid = [[], ["WoowAssistantUITests"], ["LiveExampleUITests/testFirst"],
                   ["OtherTarget/LiveExampleUITests/testFirst"], [self.CLASS + "/testMissing"],
                   [self.CLASS + "Extra"], [self.CLASS + "/"], [self.CLASS + "/*"],
                   [self.METHODS[0] + "()"], [self.METHODS[0] + "/extra"],
                   ["WoowAssistantUITests/BrowserUploadUITests"], [self.CLASS, self.CLASS],
                   [self.CLASS, self.METHODS[0]], [self.METHODS[0], self.METHODS[0]],
                   [self.CLASS + "\n"], [self.CLASS] * 129]
        for selectors in invalid:
            with self.subTest(selectors=selectors), patch.object(verifier, "ui_inventory", return_value=self.catalog), \
                 patch.object(verifier.subprocess, "run") as tool:
                self.assertEqual(verifier.verify(self.bundle, selectors)["code"], "INVALID_SELECTOR")
                tool.assert_not_called()

    def test_inventory_failure_or_empty_live_source_never_runs_xcresulttool(self):
        for outcome in [RuntimeError(self.PRIVATE), {"live_tests_excluded": []},
                        {"live_tests_excluded": [self.METHODS[0]] * 2}]:
            kwargs = {"side_effect": outcome} if isinstance(outcome, Exception) else {"return_value": outcome}
            with patch.object(verifier, "ui_inventory", **kwargs), patch.object(verifier.subprocess, "run") as tool:
                result = verifier.verify(self.bundle, [self.CLASS])
                self.assertEqual(result, {"code": "INVALID_INVENTORY", "expectedTests": 0})
                self.assertNotIn(self.PRIVATE, json.dumps(result))
                tool.assert_not_called()

    def test_passed_exact_count_returns_only_fixed_code_and_counts(self):
        payload = self.summary(environmentDescription=self.PRIVATE, topInsights=[self.PRIVATE])
        result = self.verify_payload(payload)
        self.assertEqual(result, {"code": "PASSED", "expectedTests": 2, "totalTestCount": 2,
                                 "passedTests": 2, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0})

    def test_result_failure_cannot_pass_with_matching_total_and_passed_counts(self):
        for result in ["Failed", "Unknown", "passed", None, self.PRIVATE]:
            output = self.verify_payload(self.summary(result=result))
            self.assertEqual(output["code"], "NOT_PASSED")
            self.assertNotIn(self.PRIVATE, json.dumps(output))

    def test_any_failed_skipped_or_expected_failure_is_rejected(self):
        for key in verifier.FAILURE_KEYS:
            with self.subTest(key=key):
                self.assertEqual(self.verify_payload(self.summary(**{key: 1}))["code"], "FAILURES_PRESENT")
        payload = self.summary(testFailures=[{"failureText": self.PRIVATE, "testName": self.PRIVATE}])
        output = self.verify_payload(payload)
        self.assertEqual(output["code"], "FAILURES_PRESENT")
        self.assertNotIn(self.PRIVATE, json.dumps(output))

    def test_missing_boolean_string_float_negative_or_oversized_counts_fail_closed(self):
        for key in verifier.COUNT_KEYS:
            for value in [True, "2", 2.0, -1, None, verifier.MAX_COUNT + 1]:
                with self.subTest(key=key, value=value):
                    self.assertEqual(self.verify_payload(self.summary(**{key: value}))["code"], "INVALID_SUMMARY")
            missing = self.summary()
            del missing[key]
            self.assertEqual(self.verify_payload(missing)["code"], "INVALID_SUMMARY")
        for invalid in [[], None, self.PRIVATE]:
            self.assertEqual(self.verify_payload(invalid)["code"], "INVALID_SUMMARY")

    def test_zero_missing_extra_or_inconsistent_test_counts_fail(self):
        for total, passed in [(0, 0), (1, 1), (3, 3), (2, 1), (1, 2), (14, 14)]:
            with self.subTest(total=total, passed=passed):
                result = self.verify_payload(self.summary(totalTestCount=total, passedTests=passed))
                self.assertEqual(result["code"], "COUNT_MISMATCH")

    def test_per_destination_failure_or_repeated_execution_cannot_hide_in_totals(self):
        for key in verifier.FAILURE_KEYS:
            payload = self.summary()
            payload["devicesAndConfigurations"][0][key] = 1
            self.assertEqual(self.verify_payload(payload)["code"], "FAILURES_PRESENT")
        payload = self.summary()
        payload["devicesAndConfigurations"] *= 2
        self.assertEqual(self.verify_payload(payload)["code"], "COUNT_MISMATCH")
        for invalid in [[], {}, [None], [{"passedTests": True}]]:
            self.assertEqual(self.verify_payload(self.summary(devicesAndConfigurations=invalid))["code"], "INVALID_SUMMARY")
        self.assertEqual(self.verify_payload(self.summary(testFailures={"failureText": self.PRIVATE}))["code"], "INVALID_SUMMARY")

    def test_fixed_command_timeout_and_child_environment_allowlist(self):
        env = {"PATH": "/usr/bin:/bin", "DEVELOPER_DIR": "/Applications/Xcode_16.4.app/Contents/Developer",
               "TMPDIR": str(self.bundle.parent), "TMP": "/tmp", "TEMP": "/tmp",
               "HOME": self.PRIVATE, "GITHUB_TOKEN": self.PRIVATE, "DYLD_INSERT_LIBRARIES": self.PRIVATE,
               "WOOW_MODEL_TEST_API_KEY": self.PRIVATE, "WOOW_HA_MCP_TEST_URL": self.PRIVATE,
               "SIMCTL_CHILD_WOOW_MODEL_TEST_API_KEY": self.PRIVATE}
        with patch.object(verifier.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 0, json.dumps(self.summary()).encode())) as tool:
            verifier.read_summary(self.bundle, env)
        self.assertEqual(tool.call_args.args, (["/usr/bin/xcrun", "xcresulttool", "get", "test-results", "summary",
                                               "--path", str(self.bundle.resolve())],))
        options = tool.call_args.kwargs
        self.assertEqual(options["timeout"], 120)
        self.assertEqual(options["env"], {k: env[k] for k in verifier.CHILD_ENV_KEYS})
        self.assertEqual(options["stdin"], subprocess.DEVNULL)
        self.assertEqual(options["stderr"], subprocess.DEVNULL)
        self.assertEqual(options["stdout"], subprocess.PIPE)
        self.assertFalse(options["check"])
        self.assertNotIn("shell", options)

    def test_real_child_process_does_not_receive_synthetic_secret_variables(self):
        env = verifier.child_environment({"PATH": "/usr/bin:/bin", "WOOW_MODEL_TEST_API_KEY": self.PRIVATE,
                                          "WOOW_HA_MCP_TEST_URL": self.PRIVATE, "GITHUB_TOKEN": self.PRIVATE,
                                          "SIMCTL_CHILD_PRIVATE": self.PRIVATE, "HOME": self.PRIVATE})
        child = subprocess.run([sys.executable, "-c", "import os,json;print(json.dumps(dict(os.environ)))"],
                               env=env, capture_output=True, timeout=5, check=True)
        actual = json.loads(child.stdout)
        self.assertEqual(actual["PATH"], "/usr/bin:/bin")
        self.assertNotIn(self.PRIVATE, child.stdout.decode())
        self.assertFalse(set(actual).intersection({"HOME", "GITHUB_TOKEN", "WOOW_MODEL_TEST_API_KEY",
                                                   "WOOW_HA_MCP_TEST_URL", "SIMCTL_CHILD_PRIVATE"}))

    def test_timeout_failed_tool_or_missing_tool_never_exposes_partial_output(self):
        cases = [(subprocess.TimeoutExpired([self.PRIVATE], 120, output=self.PRIVATE.encode()), "TOOL_TIMEOUT"),
                 (OSError(self.PRIVATE), "TOOL_UNAVAILABLE"),
                 (subprocess.CompletedProcess([], 65, self.PRIVATE.encode()), "TOOL_FAILED")]
        for outcome, code in cases:
            kwargs = {"side_effect": outcome} if isinstance(outcome, Exception) else {"return_value": outcome}
            with patch.object(verifier, "ui_inventory", return_value=self.catalog), \
                 patch.object(verifier.subprocess, "run", **kwargs):
                result = verifier.verify(self.bundle, [self.CLASS])
            self.assertEqual(result, {"code": code, "expectedTests": 2})
            self.assertNotIn(self.PRIVATE, json.dumps(result))

    def test_malformed_duplicate_nonfinite_or_large_json_fails_without_raw_output(self):
        for data, code in [(b"not json", "INVALID_SUMMARY"), (b"\xff", "INVALID_SUMMARY"),
                           (b'{"result":"Failed","result":"Passed"}', "INVALID_SUMMARY"),
                           (b'{"passedTests":NaN}', "INVALID_SUMMARY"),
                           (b"x" * (verifier.MAX_SUMMARY_BYTES + 1), "SUMMARY_TOO_LARGE")]:
            with patch.object(verifier, "ui_inventory", return_value=self.catalog), \
                 patch.object(verifier.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, data)):
                self.assertEqual(verifier.verify(self.bundle, [self.CLASS])["code"], code)

    def test_missing_bundle_never_runs_tool(self):
        with patch.object(verifier, "ui_inventory", return_value=self.catalog), patch.object(verifier.subprocess, "run") as tool:
            self.assertEqual(verifier.verify(self.bundle / "Missing.xcresult", [self.CLASS])["code"], "RESULT_MISSING")
            tool.assert_not_called()

    def test_cli_outputs_single_fixed_json_for_pass_failure_and_invalid_arguments(self):
        for payload, expected_exit, code in [(self.summary(), 0, "PASSED"),
                                              (self.summary(result="Failed", testFailures=[{"failureText": self.PRIVATE}]), 1, "NOT_PASSED")]:
            stdout, stderr = io.StringIO(), io.StringIO()
            with patch.object(verifier, "ui_inventory", return_value=self.catalog), \
                 patch.object(verifier.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, json.dumps(payload).encode())), \
                 contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                status = verifier.main(["--result", str(self.bundle), "--selector", self.CLASS])
            self.assertEqual(status, expected_exit)
            self.assertEqual(json.loads(stdout.getvalue())["code"], code)
            self.assertEqual(len(stdout.getvalue().splitlines()), 1)
            self.assertEqual(stderr.getvalue(), "")
            self.assertNotIn(self.PRIVATE, stdout.getvalue())
        for args in [[], ["--unknown", self.PRIVATE], ["--result", self.PRIVATE],
                     ["--result", str(self.bundle), "--sele", self.CLASS]]:
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                self.assertEqual(verifier.main(args), 1)
            self.assertEqual(json.loads(stdout.getvalue()), {"code": "INVALID_ARGUMENTS", "expectedTests": 0})
            self.assertEqual(stderr.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
