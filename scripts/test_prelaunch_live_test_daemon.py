"""Portable wrapper checks; native XCTest readiness is deliberately unclaimed."""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import prelaunch_live_test_daemon as pre


class LiveDaemonPrelaunchTests(unittest.TestCase):
    DEVICE = "12345678-1234-1234-1234-123456789ABC"

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.output = Path(folder.name)
        self.state = {"owner": pre.live.OWNER, "requested_runtime": "17.0.1",
                      "selected_runtime": {"version": "17.0.1", "buildversion": "21A342",
                                           "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-17-0"},
                      "phase": "ready", "boot_succeeded": True, "simulator_id": self.DEVICE,
                      "device_name": "Woow-Live-" + "a" * 32}
        pre.live.save(self.output, self.state)

    def read(self):
        return json.loads((self.output / pre.live.STATE).read_text())

    def test_actual_shared_helper_runs_once_with_owned_device_no_k_and_same_budget(self):
        output = io.StringIO()

        def command(args, **kwargs):
            self.assertEqual(args, ["xcrun", "simctl", "spawn", self.DEVICE, "launchctl",
                                    "kickstart", "-p", "user/501/com.apple.testmanagerd"])
            self.assertEqual(kwargs["timeout"], 120)
            self.assertNotIn("-k", args)
            self.assertEqual(self.read()["test_daemon_prelaunch"]["status"], "requested")
            return subprocess.CompletedProcess(args, 0, b"12345\n")

        with patch.object(pre.live.ios17.os, "getuid", return_value=501), \
             patch.object(pre.live.ios17.os, "kill") as alive, \
             patch.object(pre.live.ios17.time, "monotonic", side_effect=(0, 0, 106.6, 106.7, 106.8)), \
             patch.object(pre.live.ios17.subprocess, "run", side_effect=command) as child, \
             contextlib.redirect_stdout(output):
            pre.prelaunch(self.output)
        child.assert_called_once()
        alive.assert_called_once_with(12345, 0)
        diagnostic = json.loads(output.getvalue())
        self.assertEqual(diagnostic, self.read()["test_daemon_prelaunch"])
        self.assertEqual(diagnostic["status"], "process_started_handshake_unverified")
        self.assertEqual(diagnostic["attempts"], 1)
        self.assertFalse(diagnostic["handshake_verified"])
        self.assertNotIn(self.DEVICE, output.getvalue())
        self.assertNotIn("12345", output.getvalue())
        with patch.object(pre.live.ios17, "prelaunch_test_daemon") as helper:
            with self.assertRaisesRegex(pre.ReleaseError, "no retry"):
                pre.prelaunch(self.output)
            helper.assert_not_called()

    def test_shared_timeout_persists_failure_and_cannot_be_retried(self):
        output = io.StringIO()
        with patch.object(pre.live.ios17.time, "monotonic", side_effect=(0, 0, 120)), \
             patch.object(pre.live.ios17.subprocess, "run", side_effect=subprocess.TimeoutExpired(["synthetic-secret"], 120)) as child, \
             contextlib.redirect_stdout(output):
            with self.assertRaisesRegex(pre.ReleaseError, "120") as caught:
                pre.prelaunch(self.output)
        child.assert_called_once()
        self.assertEqual(self.read()["test_daemon_prelaunch"]["status"], "budget_exhausted")
        self.assertNotIn("synthetic-secret", str(caught.exception) + output.getvalue())
        with patch.object(pre.live.ios17, "prelaunch_test_daemon") as helper:
            with self.assertRaisesRegex(pre.ReleaseError, "no retry"):
                pre.prelaunch(self.output)
            helper.assert_not_called()

    def test_unowned_wrong_runtime_unbooted_deleted_or_ambiguous_device_never_invokes_helper(self):
        mutations = [{"owner": "other"}, {"requested_runtime": "18.5"},
                     {"selected_runtime": dict(self.state["selected_runtime"], version="17.0")},
                     {"selected_runtime": dict(self.state["selected_runtime"], identifier="iOS-18-5")},
                     {"phase": "booting"}, {"boot_succeeded": False}, {"cleanup_attempted": True},
                     {"simulator_deleted": True}, {"simulator_id": "booted"}, {"device_name": "Personal iPhone"}]
        for mutation in mutations:
            with self.subTest(fields=list(mutation)), patch.object(pre.live.ios17, "prelaunch_test_daemon") as helper:
                pre.live.save(self.output, dict(self.state, **mutation))
                with self.assertRaises(pre.ReleaseError):
                    pre.prelaunch(self.output)
                helper.assert_not_called()

    def test_interrupted_attempt_fence_blocks_reentry(self):
        pre.live.save(self.output, dict(self.state, test_daemon_prelaunch={"status": "requested", "attempts": 0}))
        with patch.object(pre.live.ios17, "prelaunch_test_daemon") as helper:
            with self.assertRaisesRegex(pre.ReleaseError, "no retry"):
                pre.prelaunch(self.output)
            helper.assert_not_called()

    def test_unwritable_attempt_fence_prevents_launch(self):
        with patch.object(pre.live, "save", side_effect=OSError("synthetic-secret")), \
             patch.object(pre.live.ios17, "prelaunch_test_daemon") as helper:
            with self.assertRaises(OSError):
                pre.prelaunch(self.output)
            helper.assert_not_called()

    def test_malformed_state_cli_error_never_echoes_state_or_parser_exception(self):
        for content in ['{"synthetic-secret":', '[]', '"synthetic-secret"', "x" * 8193]:
            with self.subTest(size=len(content)), patch.object(pre.live.ios17, "prelaunch_test_daemon") as helper:
                (self.output / pre.live.STATE).write_text(content)
                output, error = io.StringIO(), io.StringIO()
                with patch.object(sys, "argv", ["prelaunch", "--output", str(self.output)]), \
                     contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
                    self.assertEqual(pre.main(), 1)
                self.assertNotIn("synthetic-secret", output.getvalue() + error.getvalue())
                helper.assert_not_called()

    def test_workflow_opt_in_has_no_secret_env_upload_retry_or_extra_test_invocation(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/live-mcp.yml").read_text()
        option = workflow.split("      ios17_prelaunch:\n", 1)[1].split("\npermissions:", 1)[0]
        self.assertIn("type: boolean", option)
        self.assertIn("default: false", option)
        step = workflow.split("      - name: Prelaunch exact iOS 17 XCTest daemon (experimental)\n", 1)[1].split("      # Keep discovery", 1)[0]
        self.assertIn("if: ${{ inputs.ios17_prelaunch }}", step)
        self.assertNotIn("env:", step)
        self.assertNotIn("secrets.", step)
        self.assertLess(workflow.index("name: Build App for live MCP UI tests"), workflow.index(step))
        self.assertLess(workflow.index(step), workflow.index("name: Real MCP discovery"))
        self.assertEqual(workflow.count("test-without-building"), 1)
        self.assertNotIn("-retry-tests-on-failure", workflow)
        self.assertNotIn("upload-artifact", workflow)
        self.assertIn("if: always()", workflow.split("name: Delete only this run's simulator", 1)[1])


if __name__ == "__main__":
    unittest.main()
