"""Offline fail-closed checks. Every compiler/live subprocess is intercepted."""
import contextlib
import copy
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import run_live_learning_app as live


class LiveLearningAppRunnerTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        self.repo, self.snapshot = self.root / "repo", self.root / "snapshot"
        self.output = self.root / "result.json"
        self.snapshot.mkdir()
        paths = {"scripts/check_profile_chat_app.py"}
        paths.update("Sources/" + name + "/Fixture.swift" for name, _ in live.MODULES)
        paths.update("Sources/App/" + name + ".swift" for name in (*live.APP_SOURCES, *live.VIEWS))
        self.report = {"schema_version": 1, "checks": [
            {"name": name, "exit_code": 0} for name in sorted(live.REQUIRED_CHECKS)], "source_sha256": {}}
        for path in paths:
            data = ("// fixed synthetic source " + path + "\n").encode()
            for target in (self.repo / path, self.snapshot / "source" / path):
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
            self.report["source_sha256"][path] = hashlib.sha256(data).hexdigest()
        for name in (*live.HARNESSES.values(), "run_live_learning_app.py"):
            (self.repo / "scripts" / name).write_text("// fixed synthetic driver " + name + "\n")
        self.environment = {name: "PRIVATE_CANARY_DO_NOT_ECHO" for name in live.PRIVATE_FIELDS}
        self.save_report()

    def save_report(self, report=None):
        (self.snapshot / "report.json").write_text(json.dumps(self.report if report is None else report))

    def invoke(self):
        return live.run(self.snapshot, self.output, self.repo)

    def rejected_before_process(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.dict(live.os.environ, self.environment, clear=True), \
                patch.object(live.subprocess, "run") as child, \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            with self.assertRaises(SystemExit) as caught:
                self.invoke()
        child.assert_not_called()
        self.assertFalse(self.output.exists())
        self.assertNotIn("PRIVATE_CANARY", stdout.getvalue() + stderr.getvalue() + str(caught.exception))

    def test_valid_snapshot_captures_actual_source_bytes(self):
        hashes, captured = live.validate_snapshot(self.snapshot, self.repo)
        self.assertEqual(hashes, self.report["source_sha256"])
        self.assertEqual(set(captured), set(hashes))
        for path, data in captured.items():
            self.assertEqual(data, (self.snapshot / "source" / path).read_bytes())
            self.assertEqual(hashlib.sha256(data).hexdigest(), hashes[path])

    def test_mcp_mode_requires_private_endpoint_before_any_compile_or_request(self):
        with patch.dict(live.os.environ, self.environment, clear=True), \
                patch.object(live.subprocess, "run") as child:
            with self.assertRaisesRegex(SystemExit, "Missing model test environment"):
                live.run(self.snapshot, self.output, self.repo, "mcp")
            with self.assertRaisesRegex(SystemExit, "Unknown live App harness"):
                live.run(self.snapshot, self.output, self.repo, "unrecognized")
        child.assert_not_called()

    def test_mcp_harness_is_fixed_and_endpoint_never_reaches_compiler(self):
        seen = []
        def child(command, **kwargs):
            if command[0] == "swiftc":
                self.assertNotIn(live.MCP_PRIVATE_FIELD, kwargs["env"])
                self.assertFalse(set(live.PRIVATE_FIELDS) & set(kwargs["env"]))
                if "-DDEBUG" in command:
                    source = Path(command[command.index("-o") - 1])
                    self.assertEqual(source.read_bytes(), (self.repo / "scripts" / live.HARNESSES["mcp"]).read_bytes())
                    seen.append("mcp_source")
                return subprocess.CompletedProcess(command, 0, "", "")
            self.assertNotIn("env", kwargs)  # Executable alone inherits private fields.
            seen.append("live")
            return subprocess.CompletedProcess(command, 0, '{"passed":true}', "")
        environment = dict(self.environment, **{live.MCP_PRIVATE_FIELD: "PRIVATE_CANARY_DO_NOT_ECHO"})
        output = io.StringIO()
        with patch.dict(live.os.environ, environment, clear=True), \
                patch.object(live.subprocess, "run", side_effect=child), contextlib.redirect_stdout(output):
            self.assertEqual(live.run(self.snapshot, self.output, self.repo, "mcp"), 0)
        self.assertEqual(seen, ["mcp_source", "live"])
        self.assertNotIn("PRIVATE_CANARY", output.getvalue())
        report = json.loads(self.output.read_text())
        self.assertIn("scripts/LiveMCPLearningAppSmoke.swift", report["source_sha256"])
        self.assertNotIn("scripts/LiveLearningToolAppSmoke.swift", report["source_sha256"])

    def test_each_required_build_typecheck_and_syntax_check_is_mandatory(self):
        for name in sorted(live.REQUIRED_CHECKS):
            with self.subTest(name=name):
                report = copy.deepcopy(self.report)
                report["checks"] = [c for c in report["checks"] if c["name"] != name]
                self.save_report(report)
                self.rejected_before_process()

    def test_empty_failed_wrong_type_and_duplicate_checks_are_rejected(self):
        for value in ([], None, {}, "PRIVATE_CANARY"):
            with self.subTest(checks_type=type(value).__name__):
                self.save_report(dict(self.report, checks=value)); self.rejected_before_process()
        for code in (1, 124, False, True, "0", None):
            with self.subTest(code=code):
                report = copy.deepcopy(self.report); report["checks"][0]["exit_code"] = code
                self.save_report(report); self.rejected_before_process()
        report = copy.deepcopy(self.report); report["checks"].append(report["checks"][0])
        self.save_report(report); self.rejected_before_process()
        report = copy.deepcopy(self.report); report["checks"].append({"name": "extra-run", "exit_code": 1})
        self.save_report(report); self.rejected_before_process()

    def test_malformed_schema_and_duplicate_report_fields_fail_closed(self):
        for raw in ("[]", "null", '"PRIVATE_CANARY"', "{", '{"schema_version":1,"schema_version":1}'):
            with self.subTest(raw_kind=raw[:1]):
                (self.snapshot / "report.json").write_text(raw); self.rejected_before_process()
        for version in (None, True, "1", 2):
            self.save_report(dict(self.report, schema_version=version)); self.rejected_before_process()

    def test_missing_source_inventory_and_new_unrecorded_source_are_rejected(self):
        for path in list(self.report["source_sha256"]):
            with self.subTest(path=path):
                report = copy.deepcopy(self.report); del report["source_sha256"][path]
                self.save_report(report); self.rejected_before_process()
        self.save_report(dict(self.report, source_sha256={})); self.rejected_before_process()
        self.save_report()
        (self.repo / "Sources/AssistantMemory/New.swift").write_text("// new unrecorded source\n")
        self.rejected_before_process()

    def test_unexpected_absolute_or_traversing_paths_and_invalid_digests_are_rejected(self):
        for path in ("../PRIVATE_CANARY", "/PRIVATE_CANARY", "Sources/App/unlisted.swift"):
            report = copy.deepcopy(self.report); report["source_sha256"][path] = "0" * 64
            self.save_report(report); self.rejected_before_process()
        path = next(iter(self.report["source_sha256"]))
        for value in (None, 1, "", "x" * 64, "0" * 63):
            report = copy.deepcopy(self.report); report["source_sha256"][path] = value
            self.save_report(report); self.rejected_before_process()

    def test_matching_repo_cannot_hide_tampered_or_missing_copied_source(self):
        path = self.snapshot / "source/Sources/App/ChatSession.swift"
        path.write_text("PRIVATE_CANARY changed copied source")
        self.rejected_before_process()
        path.unlink(); self.rejected_before_process()

    def test_copied_source_cannot_hide_stale_repo(self):
        (self.repo / "Sources/App/ChatSession.swift").write_text("// changed after preflight\n")
        self.rejected_before_process()

    def test_snapshot_symlink_escape_is_rejected_even_with_matching_bytes(self):
        copied = self.snapshot / "source/Sources/App/ChatSession.swift"
        outside = self.root / "outside.swift"; outside.write_bytes(copied.read_bytes())
        copied.unlink(); copied.symlink_to(outside)
        self.rejected_before_process()

    def test_missing_private_fields_prevents_any_process(self):
        with patch.dict(live.os.environ, {}, clear=True), patch.object(live.subprocess, "run") as child:
            with self.assertRaisesRegex(SystemExit, "Missing model"):
                self.invoke()
        child.assert_not_called()

    def test_rebuild_uses_captured_bytes_not_old_dylibs_and_keeps_private_fields_out_of_compiler(self):
        calls, build_directories = [], []
        app_path = "Sources/App/ChatSession.swift"
        expected_app = (self.repo / app_path).read_bytes()
        (self.snapshot / "libAssistantMemory.dylib").write_bytes(b"stale untrusted binary")

        def child(command, **kwargs):
            calls.append(command)
            if command[0] == "swiftc":
                self.assertTrue(all(key not in kwargs["env"] for key in live.PRIVATE_FIELDS))
                self.assertGreater(kwargs["timeout"], 0); self.assertLessEqual(kwargs["timeout"], 120)
                build_root = Path(command[command.index("-I") + 1]); build_directories.append(build_root)
                self.assertNotEqual(build_root, self.snapshot)
                self.assertEqual((build_root / "source" / app_path).read_bytes(), expected_app)
                self.assertFalse(any(str(self.snapshot) in part for part in command))
                # Mutating the original snapshot after validation cannot change
                # the bytes actually compiled in the private build directory.
                (self.snapshot / "source" / app_path).write_text("// raced change\n")
                return subprocess.CompletedProcess(command, 0, "", "")
            self.assertEqual(len(calls), len(live.MODULES) + 2)
            self.assertEqual(kwargs["timeout"], 450)
            self.assertTrue(all(live.os.environ[key] == self.environment[key] for key in live.PRIVATE_FIELDS))
            return subprocess.CompletedProcess(command, 0, json.dumps({"passed": True, "model_calls": 0}), "")

        out = io.StringIO()
        with patch.dict(live.os.environ, self.environment, clear=True), \
                patch.object(live.subprocess, "run", side_effect=child), contextlib.redirect_stdout(out):
            self.assertEqual(self.invoke(), 0)
        report = json.loads(self.output.read_text())
        self.assertEqual(report["build_provenance"], "recompiled_from_verified_snapshot_bytes")
        self.assertEqual(report["source_sha256"][app_path], hashlib.sha256(expected_app).hexdigest())
        self.assertTrue(report["sources_still_current"])
        self.assertNotIn("PRIVATE_CANARY", out.getvalue() + self.output.read_text())
        self.assertTrue(all(not path.exists() for path in build_directories))

    def test_compile_failure_never_launches_live_process_or_echoes_diagnostics(self):
        out = io.StringIO()
        with patch.dict(live.os.environ, self.environment, clear=True), \
                patch.object(live.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "PRIVATE_CANARY", "PRIVATE_CANARY")) as child, \
                contextlib.redirect_stdout(out):
            with self.assertRaisesRegex(SystemExit, "did not compile"):
                self.invoke()
        self.assertEqual(child.call_count, 1)
        self.assertFalse(self.output.exists())
        self.assertNotIn("PRIVATE_CANARY", out.getvalue())

    def test_compiles_share_one_budget_and_exhaustion_prevents_next_process(self):
        with patch.dict(live.os.environ, self.environment, clear=True), \
                patch.object(live.time, "monotonic", side_effect=[0, 100, 121]), \
                patch.object(live.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as child:
            with self.assertRaisesRegex(SystemExit, "budget exhausted"):
                self.invoke()
        self.assertEqual(child.call_count, 1)
        self.assertEqual(child.call_args.kwargs["timeout"], 20)
        self.assertFalse(self.output.exists())

    def test_failed_live_result_or_source_drift_never_returns_success(self):
        for outcome in (False, "true", "drift", "process_failure"):
            with self.subTest(outcome=outcome):
                original = (self.repo / "scripts/LiveLearningToolAppSmoke.swift").read_bytes()
                self.output.unlink(missing_ok=True)

                def child(command, **kwargs):
                    if command[0] == "swiftc":
                        return subprocess.CompletedProcess(command, 0, "", "")
                    if outcome == "process_failure":
                        return subprocess.CompletedProcess(command, 1, "PRIVATE_CANARY", "PRIVATE_CANARY")
                    if outcome == "drift":
                        (self.repo / "scripts/LiveLearningToolAppSmoke.swift").write_text("// changed during run\n")
                    return subprocess.CompletedProcess(command, 0, json.dumps({"passed": True if outcome == "drift" else outcome}), "")

                out = io.StringIO()
                with patch.dict(live.os.environ, self.environment, clear=True), \
                        patch.object(live.subprocess, "run", side_effect=child), contextlib.redirect_stdout(out):
                    if outcome == "process_failure":
                        with self.assertRaisesRegex(SystemExit, "raw output was not printed"):
                            self.invoke()
                        self.assertFalse(self.output.exists())
                    else:
                        self.assertEqual(self.invoke(), 1)
                self.assertNotIn("PRIVATE_CANARY", out.getvalue())
                (self.repo / "scripts/LiveLearningToolAppSmoke.swift").write_bytes(original)

    def test_cli_timeout_and_parse_errors_never_echo_private_exception_data(self):
        errors = [subprocess.TimeoutExpired(["PRIVATE_CANARY"], 120, output="PRIVATE_CANARY", stderr="PRIVATE_CANARY"),
                  OSError("PRIVATE_CANARY"), ValueError("PRIVATE_CANARY"), TypeError("PRIVATE_CANARY")]
        for error in errors:
            with self.subTest(error=type(error).__name__):
                out = io.StringIO()
                with patch.object(live.sys, "argv", ["runner", "--snapshot", str(self.snapshot), "--output", str(self.output)]), \
                        patch.object(live, "run", side_effect=error), patch.object(live.subprocess, "run") as child, \
                        contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
                    with self.assertRaises(SystemExit) as caught:
                        live.main()
                child.assert_not_called()
                self.assertNotIn("PRIVATE_CANARY", out.getvalue() + str(caught.exception))


if __name__ == "__main__":
    unittest.main()
