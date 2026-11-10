"""Portable orchestration regressions; these do not claim a native iOS boot."""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import prepare_live_simulator as live


class LiveSimulatorTests(unittest.TestCase):
    DEVICE = "12345678-1234-1234-1234-123456789ABC"
    R17 = {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-17-0",
           "version": "17.0.1", "buildversion": "21A342", "isAvailable": True}
    R18 = {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
           "version": "18.5", "buildversion": "22F76", "isAvailable": True}
    FINISHED = b"Status=4294967295, isTerminal=YES, Elapsed=03:42.\n\tFinished\n"
    MIGRATION_FAILED = b"Status=3, isTerminal=YES, Elapsed=05:02.\n\tData Migration Failed\n"

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)
        self.output = self.root / "simulator"
        self.env = self.root / "github-env"
        self.commands = []

    def command(self, args, *unused, **kwargs):
        self.commands.append((args, kwargs))
        if args == ["xcodebuild", "-version"]:
            return b"Xcode 16.4\nBuild version 16F6\n"
        if args[:3] == ["xcrun", "simctl", "create"]:
            return self.DEVICE.encode()
        if args[:3] in (["xcrun", "simctl", "shutdown"], ["xcrun", "simctl", "delete"]):
            self.assertEqual(args[3], self.DEVICE)
            self.assertEqual(kwargs["timeout"], 60)
            return b""
        raise AssertionError("Unexpected command")

    @contextlib.contextmanager
    def tools(self, **overrides):
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(live.platform, "machine", return_value="arm64"))
            stack.enter_context(patch.object(live, "run", side_effect=overrides.get("command", self.command)))
            runtime = stack.enter_context(patch.object(live.ios17, "ensure_runtime", return_value=self.R17))
            stack.enter_context(patch.object(live.ios17, "inventory", return_value={"runtimes": [self.R17, self.R18]}))
            boot = stack.enter_context(patch.object(live.ios17, "boot_simulator", side_effect=overrides.get("boot")))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            yield runtime, boot

    def report(self):
        return json.loads((self.output / live.STATE).read_text())

    def test_exact_patch_selection_rejects_missing_unavailable_ambiguous_and_other_versions(self):
        for requested, correct in [("17.0.1", self.R17), ("18.5", self.R18)]:
            with self.subTest(requested=requested):
                self.assertEqual(live.select_runtime({"runtimes": [correct]}, requested)["version"], requested)
                for items in [[], [correct, correct], [dict(correct, isAvailable=False)],
                              [dict(correct, version="26.2")]]:
                    with self.assertRaises(live.ReleaseError):
                        live.select_runtime({"runtimes": items}, requested)
        for requested in ["17.0", "17.5", "26.2", "latest"]:
            with self.assertRaises(live.ReleaseError):
                live.select_runtime({"runtimes": [self.R17, self.R18]}, requested)

    def test_17_creates_owned_iphone15_and_exports_only_after_boot(self):
        def boot(output, device, report):
            self.assertFalse(self.env.exists())
            self.assertEqual(self.report()["simulator_id"], self.DEVICE)
            self.assertEqual(report["phase"], "booting")
        with self.tools(boot=boot) as (runtime, native_boot):
            result = live.prepare(self.output, "17.0.1", self.env)
        runtime.assert_called_once()
        self.assertEqual(runtime.call_args.args[1:3], ("17.0.1", True))
        native_boot.assert_called_once()
        created = next(args for args, _ in self.commands if "create" in args)
        self.assertRegex(created[3], r"^Woow-Live-[0-9a-f]{32}$")
        self.assertEqual(created[4:], [live.RUNTIMES["17.0.1"], self.R17["identifier"]])
        self.assertEqual(self.env.read_text(), "WOOW_LIVE_SIMULATOR=" + self.DEVICE + "\nWOOW_LIVE_RUNTIME=iOS-17-0\n")
        self.assertTrue(result["boot_succeeded"])
        self.assertEqual(result["phase"], "ready")
        self.assertFalse(any("delete" in args for args, _ in self.commands))

    def test_default_18_uses_installed_exact_runtime_and_its_original_device_class(self):
        with self.tools() as (installer, _):
            live.prepare(self.output, "18.5", self.env)
        installer.assert_not_called()
        created = next(args for args, _ in self.commands if "create" in args)
        self.assertEqual(created[4:], [live.RUNTIMES["18.5"], self.R18["identifier"]])
        self.assertIn("WOOW_LIVE_RUNTIME=iOS-18-5\n", self.env.read_text())

    def test_existing_installer_and_boot_paths_run_once_for_missing_exact_17(self):
        installer, inventory, boot = live.ios17.ensure_runtime, live.ios17.inventory, live.ios17.boot_simulator
        def child(args, **kw):
            if args[0] == "xcodebuild":
                self.assertEqual(args, ["xcodebuild", "-downloadPlatform", "iOS", "-buildVersion", "17.0.1"])
                self.assertEqual(kw["timeout"], 1200)
                kw["stdout"].write(b"synthetic installer completion\n")
            else:
                self.assertEqual(args, ["xcrun", "simctl", "bootstatus", self.DEVICE, "-b"])
                self.assertEqual(kw["timeout"], 900)
                kw["stdout"].write(self.FINISHED)
            return subprocess.CompletedProcess(args, 0)
        payloads = [json.dumps({"runtimes": [self.R18]}).encode(),
                    json.dumps({"runtimes": [self.R18, self.R17]}).encode()]
        with self.tools(), patch.object(live.ios17, "ensure_runtime", new=installer), \
             patch.object(live.ios17, "inventory", new=inventory), \
             patch.object(live.ios17, "boot_simulator", new=boot), \
             patch.object(live.ios17, "run", side_effect=payloads) as queries, \
             patch.object(live.ios17.subprocess, "run", side_effect=child) as children:
            live.prepare(self.output, "17.0.1", self.env)
        self.assertEqual(children.call_count, 2)
        self.assertEqual(queries.call_count, 2)
        self.assertEqual(self.report()["selected_runtime"]["version"], "17.0.1")
        self.assertEqual(self.report()["boot_terminal_status"], 4294967295)
        self.assertFalse(self.report()["boot_data_migration_failed"])
        self.assertTrue((self.output / "runtimes-before.json").exists())
        self.assertTrue((self.output / "runtimes-after.json").exists())

    def test_preflight_blocks_wrong_architecture_or_xcode_before_runtime_changes(self):
        for architecture, xcode in [("x86_64", b"Xcode 16.4\nBuild version 16F6"),
                                    ("arm64", b"Xcode 26.2\nBuild version 17C52")]:
            with self.subTest(architecture=architecture), self.tools() as (installer, boot):
                output = self.root / architecture
                with patch.object(live.platform, "machine", return_value=architecture), \
                     patch.object(live, "run", return_value=xcode) as command:
                    with self.assertRaises(live.ReleaseError): live.prepare(output, "17.0.1", self.env)
                installer.assert_not_called()
                boot.assert_not_called()
                self.assertLessEqual(command.call_count, 1)
        self.assertFalse(self.env.exists())

    def test_runtime_version_and_identifier_cannot_inject_environment_or_select_other_os(self):
        for index, runtime in enumerate([dict(self.R17, identifier=self.R18["identifier"]),
                                         dict(self.R17, version="17.5"),
                                         dict(self.R17, identifier=self.R17["identifier"] + "\nINJECTED=1")]):
            with self.subTest(runtime=index), self.tools() as (installer, boot):
                installer.return_value = runtime
                with self.assertRaises(live.ReleaseError):
                    live.prepare(self.root / str(index), "17.0.1", self.env)
                boot.assert_not_called()
        self.assertFalse(self.env.exists())
        self.assertFalse(any("create" in args for args, _ in self.commands))

    def test_missing_18_does_not_install_or_fall_back(self):
        with self.tools() as (installer, boot), patch.object(live.ios17, "inventory", return_value={"runtimes": [self.R17]}):
            with self.assertRaises(live.ReleaseError): live.prepare(self.output, "18.5", self.env)
            installer.assert_not_called()
            boot.assert_not_called()
        self.assertFalse(any("create" in args for args, _ in self.commands))

    def test_invalid_create_uuid_never_reaches_boot_cleanup_or_env(self):
        def command(args, *a, **kw):
            if "create" in args: return b"bad-id\nINJECTED=1"
            return self.command(args, *a, **kw)
        with self.tools(command=command) as (_, boot):
            with self.assertRaisesRegex(live.ReleaseError, "有效 UUID"):
                live.prepare(self.output, "17.0.1", self.env)
            boot.assert_not_called()
        self.assertFalse(self.env.exists())
        self.assertFalse(any("delete" in args for args, _ in self.commands))

    def test_real_boot_parser_rejects_migration_and_timeout_without_environment_export(self):
        for index, (log, outcome) in enumerate([(self.MIGRATION_FAILED, 0), (self.FINISHED, 70),
                                                (self.FINISHED, "timeout"), (self.FINISHED, 0)]):
            def child(args, **kw):
                self.assertEqual(args, ["xcrun", "simctl", "bootstatus", self.DEVICE, "-b"])
                self.assertEqual(kw["timeout"], 900)
                kw["stdout"].write(log)
                if outcome == "timeout": raise subprocess.TimeoutExpired(args, 900)
                return subprocess.CompletedProcess(args, outcome)
            output = self.root / str(index)
            env = self.root / (str(index) + "-env")
            original_boot = live.ios17.boot_simulator
            with self.subTest(outcome=outcome), self.tools(), \
                 patch.object(live.ios17, "boot_simulator", side_effect=original_boot), \
                 patch.object(live.ios17.subprocess, "run", side_effect=child) as tool:
                if index < 3:
                    with self.assertRaises(live.ReleaseError): live.prepare(output, "17.0.1", env)
                    self.assertFalse(env.exists())
                    self.assertTrue(json.loads((output / live.STATE).read_text())["simulator_deleted"])
                else:
                    live.prepare(output, "17.0.1", env)
                    self.assertTrue(env.exists())
                tool.assert_called_once()

    def test_failure_during_env_export_deletes_only_new_device(self):
        with self.tools():
            with self.assertRaises(OSError):
                live.prepare(self.output, "18.5", self.root / "missing" / "env")
        self.assertTrue(self.report()["simulator_deleted"])
        self.assertEqual([args for args, _ in self.commands if "delete" in args],
                         [["xcrun", "simctl", "delete", self.DEVICE]])

    def test_cleanup_after_shutdown_error_still_deletes_and_is_idempotent(self):
        with self.tools(): live.prepare(self.output, "18.5", self.env)
        def command(args, *a, **kw):
            if "shutdown" in args: raise live.ReleaseError("already shut down")
            return self.command(args, *a, **kw)
        with patch.object(live, "run", side_effect=command):
            self.assertEqual(live.cleanup(self.output)["cleanup"], "deleted")
            self.assertEqual(live.cleanup(self.output)["cleanup"], "already_deleted")
        self.assertFalse(self.report()["shutdown_succeeded"])
        self.assertEqual(sum("delete" in args for args, _ in self.commands), 1)

    def test_cleanup_error_does_not_mask_boot_failure_or_retry(self):
        def command(args, *a, **kw):
            if "delete" in args: raise live.ReleaseError("secondary cleanup failure")
            return self.command(args, *a, **kw)
        with self.tools(command=command, boot=live.ReleaseError("primary boot failure")):
            with self.assertRaisesRegex(live.ReleaseError, "primary boot failure"):
                live.prepare(self.output, "17.0.1", self.env)
        self.assertFalse(self.report()["simulator_deleted"])
        with patch.object(live, "run") as tool:
            with self.assertRaises(live.ReleaseError): live.cleanup(self.output)
            tool.assert_not_called()

    def test_cleanup_rejects_unowned_or_malformed_state_without_any_mutation(self):
        self.assertEqual(live.cleanup(self.output)["cleanup"], "no_created_simulator")
        self.output.mkdir()
        valid = {"owner": live.OWNER, "requested_runtime": "18.5", "simulator_id": self.DEVICE,
                 "device_name": "Woow-Live-" + "a" * 32}
        for wrong in [dict(valid, owner="other"), dict(valid, simulator_id="all"),
                      dict(valid, device_name="Personal iPhone"), dict(valid, requested_runtime="26.2")]:
            live.save(self.output, wrong)
            with patch.object(live, "run") as tool:
                with self.assertRaises(live.ReleaseError): live.cleanup(self.output)
                tool.assert_not_called()

    def test_existing_state_is_not_overwritten(self):
        self.output.mkdir()
        (self.output / live.STATE).write_text("original ownership")
        with self.tools() as (runtime, boot):
            with self.assertRaises(FileExistsError): live.prepare(self.output, "18.5", self.env)
            runtime.assert_not_called()
            boot.assert_not_called()
        self.assertEqual((self.output / live.STATE).read_text(), "original ownership")
        self.assertEqual(self.commands, [])

    def test_unexpected_tool_data_is_not_printed_by_cli(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(live.sys, "argv", ["prepare", "--github-env", str(self.env)]), \
             patch.object(live, "prepare", side_effect=ValueError("synthetic-private-marker")), \
             contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.assertEqual(live.main(), 1)
        self.assertNotIn("synthetic-private-marker", stdout.getvalue() + stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
