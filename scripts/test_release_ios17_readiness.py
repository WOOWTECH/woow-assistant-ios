import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import release_ios17 as ios17
from release_ios import ReleaseError


SIMULATOR = "12345678-1234-1234-1234-123456789ABC"
SERVICE = "user/501/com.apple.testmanagerd"


class DaemonPrelaunchTests(unittest.TestCase):
    def run_prelaunch(self, child, ticks=(0, 0, 106.6, 106.7, 106.8), liveness=None):
        report = {}
        with patch.object(ios17.os, "getuid", return_value=501), \
             patch.object(ios17.os, "kill", side_effect=liveness), \
             patch.object(ios17.time, "monotonic", side_effect=ticks), \
             patch.object(ios17.subprocess, "run", side_effect=child):
            ios17.prelaunch_test_daemon(SIMULATOR, report)
        return report["test_daemon_prelaunch"]

    def test_one_prelaunch_uses_only_selected_simulator_and_shared_budget(self):
        calls = []

        def child(args, **kwargs):
            calls.append((args, kwargs))
            self.assertEqual(args[:5], ["xcrun", "simctl", "spawn", SIMULATOR, "launchctl"])
            self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
            self.assertEqual(kwargs["stderr"], subprocess.DEVNULL)
            self.assertNotIn("-k", args)
            self.assertNotIn("TOKEN", kwargs["env"])
            self.assertNotIn("SIMCTL_CHILD_SECRET", kwargs["env"])
            return subprocess.CompletedProcess(args, 0, b"12345\n")

        with patch.dict(os.environ, {"TOKEN": "synthetic-private-value", "SIMCTL_CHILD_SECRET": "synthetic-private-value"}):
            result = self.run_prelaunch(child)
        self.assertEqual([call[0][5:] for call in calls], [["kickstart", "-p", SERVICE]])
        self.assertEqual(calls[0][1]["timeout"], 120)
        self.assertEqual(result["status"], "process_started_handshake_unverified")
        self.assertEqual(result["attempts"], 1)
        self.assertFalse(result["handshake_verified"])
        self.assertTrue(result["process_alive"])
        self.assertNotIn("synthetic-private-value", json.dumps(result))
        self.assertNotIn("12345", json.dumps(result))

    def test_budget_includes_launch_before_liveness_and_never_restarts(self):
        calls = []

        def child(args, **kwargs):
            calls.append(args)
            return subprocess.CompletedProcess(args, 0, b"12345\n")

        with self.assertRaisesRegex(ReleaseError, "共用 120 秒"):
            self.run_prelaunch(child, ticks=(0, 0, 120, 120))
        self.assertEqual(len(calls), 1)

    def test_command_timeout_failure_or_io_error_are_fixed_and_not_retried(self):
        for failure in [subprocess.TimeoutExpired(["synthetic-private-value"], 120),
                        OSError("synthetic-private-value"), None]:
            with self.subTest(failure=type(failure).__name__):
                calls = []

                def child(args, **kwargs):
                    calls.append(args)
                    if failure is not None:
                        raise failure
                    return subprocess.CompletedProcess(args, 1, b"synthetic-private-value")

                with self.assertRaises(ReleaseError) as caught:
                    self.run_prelaunch(child, ticks=(0, 0, 120))
                self.assertNotIn("synthetic-private-value", str(caught.exception))
                self.assertEqual(len(calls), 1)

    def test_invalid_pid_cannot_be_used_as_command_input(self):
        for pid in [b"0", b"-1", b"12345 extra", b"$(echo secret)", b"12345\n67890", b"9" * 11]:
            with self.subTest(pid=pid), patch.object(ios17.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, pid)) as child:
                report = {}
                with self.assertRaises(ReleaseError):
                    ios17.prelaunch_test_daemon(SIMULATOR, report)
                self.assertEqual(child.call_count, 1)
                self.assertEqual(report["test_daemon_prelaunch"]["status"], "invalid_pid")

    def test_dead_or_inaccessible_process_cannot_be_reported_as_started(self):
        def child(args, **kwargs):
            return subprocess.CompletedProcess(args, 0, b"12345\n")
        for failure in (ProcessLookupError("synthetic-private-value"), PermissionError("synthetic-private-value")):
            with self.subTest(failure=type(failure).__name__), self.assertRaisesRegex(ReleaseError, "存活尚未確認"):
                self.run_prelaunch(child, ticks=(0, 0, 106.6, 106.7), liveness=failure)

    def test_liveness_is_public_signal_zero_and_still_within_shared_budget(self):
        report = {}
        with patch.object(ios17.os, "kill") as alive, \
             patch.object(ios17.time, "monotonic", side_effect=(0, 0, 119, 120, 120)), \
             patch.object(ios17.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, b"12345\n")) as child:
            with self.assertRaisesRegex(ReleaseError, "共用 120 秒"):
                ios17.prelaunch_test_daemon(SIMULATOR, report)
        alive.assert_called_once_with(12345, 0)
        self.assertEqual(child.call_count, 1)

    def test_invalid_simulator_never_runs_a_command(self):
        with patch.object(ios17.subprocess, "run") as child:
            report = {}
            with self.assertRaises(ReleaseError):
                ios17.prelaunch_test_daemon("booted", report)
            child.assert_not_called()
            self.assertEqual(report["test_daemon_prelaunch"]["attempts"], 0)

    def test_oversized_service_output_fails_without_echoing_it(self):
        def child(args, **kwargs):
            return subprocess.CompletedProcess(args, 0, b"x" * 65)

        with self.assertRaisesRegex(ReleaseError, "格式不符"):
            self.run_prelaunch(child, ticks=(0, 0, 1))

    def test_cli_is_opt_in_and_workflow_keeps_experiment_separate(self):
        for flags, enabled in (([], False), (["--prelaunch-test-daemon"], True)):
            with self.subTest(enabled=enabled), patch.object(sys, "argv", ["release_ios17.py", *flags]), \
                 patch.object(ios17, "execute") as execute:
                self.assertEqual(ios17.main(), 0)
                self.assertIs(execute.call_args.args[-1], enabled)
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/release-ios.yml").read_text()
        option = workflow.split("      ios17_prelaunch:\n", 1)[1].split("\npermissions:", 1)[0]
        self.assertIn("type: boolean", option)
        self.assertIn("default: false", option)
        group = next(line for line in workflow.splitlines() if line.strip().startswith("group:"))
        self.assertIn("inputs.ios17_prelaunch", group)
        self.assertIn('if [ "$IOS17_PRELAUNCH" = true ]; then', workflow)

    def test_failure_is_saved_before_test_and_simulator_cleanup(self):
        simulator = SIMULATOR
        calls = []

        def command(args, *unused, **kwargs):
            if "-version" in args:
                return b"Xcode 16.4"
            if "-showBuildSettings" in args:
                return b"[]"
            if "create" in args:
                return simulator.encode()
            if "devices" in args:
                return b'{"devices": {}}'
            if "delete" in args:
                calls.append("delete")
            return b""

        def prelaunch(device, report):
            self.assertEqual(device, simulator)
            report["test_daemon_prelaunch"] = {"status": "budget_exhausted", "attempts": 1}
            raise ReleaseError("primary prelaunch failure")

        def child(args, **kwargs):
            self.assertEqual(args, ["xcrun", "simctl", "shutdown", simulator])
            saved = json.loads((output / "report.json").read_text())
            self.assertEqual(saved["test_daemon_prelaunch"]["status"], "budget_exhausted")
            calls.append("shutdown")
            return subprocess.CompletedProcess(args, 0)

        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "result"
            with patch.object(ios17, "run", side_effect=command), \
                 patch.object(ios17, "boot_simulator"), \
                 patch.object(ios17, "prelaunch_test_daemon", side_effect=prelaunch), \
                 patch.object(ios17, "ensure_runtime", return_value={"version": "17.0.1", "identifier": "synthetic"}), \
                 patch.object(ios17, "generate_project", return_value=output / "Project.xcodeproj"), \
                 patch.object(ios17, "verify_settings"), \
                 patch.object(ios17.subprocess, "run", side_effect=child), patch("builtins.print"):
                with self.assertRaisesRegex(ReleaseError, "primary prelaunch failure"):
                    ios17.execute(output, "17.0.1", False, "startup-smoke", prelaunch_daemon=True)
            report = json.loads((output / "report.json").read_text())
            self.assertFalse(report["selected_tests_succeeded"])
            self.assertFalse((output / "tests.log").exists())
            self.assertEqual(report["phase"], "prelaunching_test_daemon")
            self.assertEqual(calls, ["shutdown", "delete"])


if __name__ == "__main__":
    unittest.main()
