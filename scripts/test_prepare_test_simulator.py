"""Portable lifecycle/ownership checks. Native simulator acceptance remains CI work."""
import contextlib
import copy
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import prepare_test_simulator as simulator


class TestSimulatorLifecycleTests(unittest.TestCase):
    SOURCE = "11111111-2222-3333-4444-555555555555"
    CREATED = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    OTHER = "12345678-1234-5678-1234-123456789ABC"
    RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
    TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17"

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.state = self.root / "test-simulator.json"
        self.commands = []
        self.inventory = {"devices": {self.RUNTIME: [{
            "udid": self.SOURCE, "name": "iPhone 17", "deviceTypeIdentifier": self.TYPE,
            "isAvailable": True, "state": "Shutdown"}]}}
        self.runtimes = {"runtimes": [{"identifier": self.RUNTIME, "isAvailable": True,
                                     "version": "26.2", "buildversion": "23C54"}]}
        self.types = {"devicetypes": [{"identifier": self.TYPE, "name": "iPhone 17"}]}

    def read(self):
        return json.loads(self.state.read_text())

    def write(self, report):
        self.state.write_text(json.dumps(report))

    def command(self, *args):
        self.commands.append(args)
        if args == ("list", "devices", "--json"):
            return json.dumps(self.inventory)
        if args == ("list", "runtimes", "--json"):
            return json.dumps(self.runtimes)
        if args == ("list", "devicetypes", "--json"):
            return json.dumps(self.types)
        if args[0] == "create":
            self.assertEqual(args[2:], (self.TYPE, self.RUNTIME))
            self.assertEqual(self.read()["phase"], "creating")
            self.assertIsNone(self.read()["simulator_id"])
            self.inventory["devices"][self.RUNTIME].append({
                "udid": self.CREATED, "name": args[1], "deviceTypeIdentifier": args[2],
                "isAvailable": True, "state": "Shutdown"})
            return self.CREATED
        if args[0] in ("shutdown", "delete"):
            self.assertEqual(args[1:], (self.CREATED,))
            self.assertTrue(self.read()["delete_attempted"])
            return ""
        raise AssertionError("Unexpected simctl operation")

    def prepare(self, fresh=True, command=None):
        with patch.object(simulator, "command", side_effect=command or self.command):
            return simulator.prepare(self.state, "iOS-26-2", "iPhone 17", fresh)

    def cleanup(self, command=None):
        with patch.object(simulator, "command", side_effect=command or self.command):
            return simulator.cleanup(self.state)

    def mutations(self):
        return [args for args in self.commands if args[0] != "list"]

    def test_default_reuses_exact_selected_device_and_cleanup_never_mutates_it(self):
        self.assertEqual(self.prepare(fresh=False), self.SOURCE)
        self.assertEqual(self.read()["mode"], "existing")
        self.assertEqual(self.read()["runtime_build"], "23C54")
        self.commands.clear()
        self.assertEqual(self.cleanup(), "not_owned_no_device_changed")
        self.assertEqual(self.commands, [])
        self.assertEqual(self.read()["simulator_id"], self.SOURCE)

    def test_fresh_peer_uses_actual_installed_runtime_and_type_and_persists_before_boot(self):
        self.assertEqual(self.prepare(), self.CREATED)
        report = self.read()
        self.assertEqual(report["phase"], "ready_to_boot")
        self.assertEqual(report["source_simulator_id"], self.SOURCE)
        self.assertEqual(report["simulator_id"], self.CREATED)
        self.assertEqual(report["runtime_identifier"], self.RUNTIME)
        self.assertEqual(report["runtime_version"], "26.2")
        self.assertEqual(report["device_type_identifier"], self.TYPE)
        self.assertRegex(report["created_name"], r"^Woow-CI-[0-9a-f]{32}$")
        self.assertIn("identity_verified_at", report)
        self.assertEqual(self.mutations(), [("create", report["created_name"], self.TYPE, self.RUNTIME)])

    def test_same_metadata_selection_supports_all_three_matrix_variants(self):
        for suffix, model, type_name, version, build in [
                ("iOS-18-5", "iPhone SE (3rd generation)", "iPhone-SE-3rd-generation", "18.5", "22F77"),
                ("iOS-18-5", "iPhone 16 Pro Max", "iPhone-16-Pro-Max", "18.5", "22F77"),
                ("iOS-26-2", "iPhone 17", "iPhone-17", "26.2", "23C54")]:
            with self.subTest(model=model):
                runtime = "com.apple.CoreSimulator.SimRuntime." + suffix
                type_id = "com.apple.CoreSimulator.SimDeviceType." + type_name
                devices = {"devices": {runtime: [{"udid": self.SOURCE, "name": model,
                            "deviceTypeIdentifier": type_id, "isAvailable": True}]}}
                runtimes = {"runtimes": [{"identifier": runtime, "isAvailable": True,
                            "version": version, "buildversion": build}]}
                types = {"devicetypes": [{"identifier": type_id, "name": model}]}
                result = simulator.selection(devices, runtimes, types, suffix, model)
                self.assertEqual(result["runtime_identifier"], runtime)
                self.assertEqual(result["device_type_identifier"], type_id)
                self.assertEqual(result["runtime_build"], build)

    def test_missing_unavailable_ambiguous_or_mismatched_metadata_cannot_create(self):
        original = (copy.deepcopy(self.inventory), copy.deepcopy(self.runtimes), copy.deepcopy(self.types))
        for defect in ("wrong-runtime", "unavailable-runtime", "duplicate-runtime", "missing-type",
                       "wrong-type-name", "duplicate-type", "wrong-device-name", "invalid-uuid"):
            with self.subTest(defect=defect):
                self.inventory, self.runtimes, self.types = copy.deepcopy(original)
                item = self.inventory["devices"][self.RUNTIME][0]
                if defect == "wrong-runtime": self.runtimes["runtimes"][0]["identifier"] += "-1"
                elif defect == "unavailable-runtime": self.runtimes["runtimes"][0]["isAvailable"] = False
                elif defect == "duplicate-runtime": self.runtimes["runtimes"] *= 2
                elif defect == "missing-type": del item["deviceTypeIdentifier"]
                elif defect == "wrong-type-name": self.types["devicetypes"][0]["name"] = "iPhone 16"
                elif defect == "duplicate-type": self.types["devicetypes"] *= 2
                elif defect == "wrong-device-name": item["name"] = "iPhone 16"
                elif defect == "invalid-uuid": item["udid"] = "all"
                with self.assertRaises(ValueError): self.prepare()
                self.assertFalse(self.state.exists())
                self.assertEqual(self.mutations(), [])

    def test_preexisting_state_and_link_are_refused_before_any_simctl_command(self):
        self.state.write_text("existing")
        with self.assertRaises(ValueError): self.prepare()
        self.state.unlink()
        self.state.symlink_to(self.root / "missing-target")
        with self.assertRaises(ValueError): self.prepare()
        self.assertEqual(self.commands, [])

    def test_create_cannot_return_a_preexisting_uuid_or_unvalidated_text(self):
        for index, value in enumerate((self.SOURCE, "all", self.CREATED + "\nSECOND=1")):
            with self.subTest(value=index):
                self.state = self.root / (str(index) + ".json")
                def command(*args):
                    if args[0] == "create": return value
                    return self.command(*args)
                with self.assertRaises(ValueError): self.prepare(command=command)
                self.assertEqual(self.read()["phase"], "create_failed")
                self.assertIsNone(self.read()["simulator_id"])
                self.assertEqual(self.cleanup(), "owned_device_not_present")
                self.assertEqual(self.mutations(), [])

    def test_created_identity_must_match_before_uuid_is_returned(self):
        def command(*args):
            result = self.command(*args)
            if args[0] == "create":
                self.inventory["devices"][self.RUNTIME][-1]["deviceTypeIdentifier"] = self.TYPE + "-other"
            return result
        with self.assertRaisesRegex(ValueError, "does not match"): self.prepare(command=command)
        self.assertEqual(self.read()["simulator_id"], self.CREATED)
        with self.assertRaisesRegex(ValueError, "identity changed"): self.cleanup()
        self.assertEqual([args[0] for args in self.mutations()], ["create"])

    def test_lost_create_response_can_cleanup_only_checkpointed_unique_identity(self):
        def command(*args):
            result = self.command(*args)
            if args[0] == "create": raise ValueError("bounded create timeout")
            return result
        with self.assertRaises(ValueError): self.prepare(command=command)
        self.assertIsNone(self.read()["simulator_id"])
        self.assertEqual(self.cleanup(), "deleted")
        self.assertEqual(self.read()["simulator_id"], self.CREATED)
        self.assertEqual(self.mutations()[-2:], [("shutdown", self.CREATED), ("delete", self.CREATED)])

    def test_failed_create_without_a_device_does_not_delete_anything(self):
        def command(*args):
            if args[0] == "create": raise ValueError("create failed before creation")
            return self.command(*args)
        with self.assertRaises(ValueError): self.prepare(command=command)
        self.assertEqual(self.cleanup(), "owned_device_not_present")
        self.assertEqual(self.mutations(), [])

    def test_cleanup_deletes_only_owned_uuid_even_when_shutdown_reports_already_shutdown(self):
        self.prepare()
        self.commands.clear()
        def command(*args):
            result = self.command(*args)
            if args[0] == "shutdown": raise ValueError("already shutdown")
            return result
        self.assertEqual(self.cleanup(command), "deleted")
        self.assertFalse(self.read()["shutdown_succeeded"])
        self.assertEqual(self.mutations(), [("shutdown", self.CREATED), ("delete", self.CREATED)])
        self.commands.clear()
        self.assertEqual(self.cleanup(), "already deleted; no device changed")
        self.assertEqual(self.commands, [])

    def test_delete_failure_is_recorded_and_cannot_automatically_retry(self):
        self.prepare()
        def command(*args):
            result = self.command(*args)
            if args[0] == "delete": raise ValueError("delete failed")
            return result
        with self.assertRaises(ValueError): self.cleanup(command)
        self.assertEqual(self.read()["cleanup"], "delete_failed")
        self.commands.clear()
        with self.assertRaisesRegex(ValueError, "refusing automatic retry"): self.cleanup()
        self.assertEqual(self.commands, [])

    def test_cleanup_rejects_foreign_renamed_ambiguous_or_retyped_device(self):
        self.prepare()
        original = copy.deepcopy(self.inventory)
        for defect in ("renamed", "wrong-runtime", "wrong-type", "wrong-id", "duplicate-name"):
            with self.subTest(defect=defect):
                self.inventory = copy.deepcopy(original)
                created = self.inventory["devices"][self.RUNTIME][-1]
                if defect == "renamed": created["name"] = "iPhone 17"
                elif defect == "wrong-runtime": self.inventory["devices"][self.RUNTIME + "-1"] = [self.inventory["devices"][self.RUNTIME].pop()]
                elif defect == "wrong-type": created["deviceTypeIdentifier"] = self.TYPE + "-other"
                elif defect == "wrong-id": created["udid"] = self.OTHER
                elif defect == "duplicate-name": self.inventory["devices"][self.RUNTIME].append(dict(created, udid=self.OTHER))
                self.commands.clear()
                with self.assertRaises(ValueError): self.cleanup()
                self.assertEqual(self.mutations(), [])

    def test_cleanup_refuses_unowned_corrupt_oversized_and_linked_records(self):
        self.prepare()
        report = self.read()
        cases = [dict(report, owner="someone-else"), dict(report, simulator_id=self.SOURCE),
                 dict(report, created_name="iPhone 17"), dict(report, creation_attempted=False),
                 dict(report, mode="other"), dict(report, simulator_id="all")]
        for value in cases:
            self.write(value)
            self.commands.clear()
            with self.assertRaises(ValueError): self.cleanup()
            self.assertEqual(self.mutations(), [])
        for value in ("{bad", " " * (simulator.MAX_STATE_BYTES + 1)):
            self.state.write_text(value)
            with self.assertRaises(ValueError): self.cleanup()
        self.state.unlink()
        self.state.symlink_to(self.root / "missing-target")
        with self.assertRaises(ValueError): self.cleanup()

    def test_missing_state_or_missing_owned_device_never_mutates_existing_devices(self):
        self.assertEqual(self.cleanup(), "no ownership record; no device changed")
        self.assertEqual(self.commands, [])
        self.prepare()
        self.inventory["devices"][self.RUNTIME].pop()
        self.commands.clear()
        self.assertEqual(self.cleanup(), "owned_device_not_present")
        self.assertEqual(self.mutations(), [])

    def test_native_command_bounds_sanitizes_failure_and_never_uses_shell(self):
        with patch.object(simulator.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, b"result\n")) as child:
            self.assertEqual(simulator.command("list", "devices", "--json"), "result")
        self.assertEqual(child.call_args.args[0], ["xcrun", "simctl", "list", "devices", "--json"])
        self.assertEqual(child.call_args.kwargs, {"check": True, "capture_output": True, "timeout": 60})
        for failure in (subprocess.TimeoutExpired("hidden", 60),
                        subprocess.CalledProcessError(1, "hidden", stderr=b"private-path"), OSError("private-path")):
            with patch.object(simulator.subprocess, "run", side_effect=failure):
                with self.assertRaisesRegex(ValueError, "simctl list failed or exceeded 60 seconds") as error:
                    simulator.command("list", "devices", "--json")
                self.assertNotIn("private-path", str(error.exception))

    def test_cli_publishes_only_verified_uuid_and_defaults_to_existing(self):
        with patch.object(sys, "argv", ["script", "prepare", "--runtime", "iOS-26-2", "--device", "iPhone 17", "--state", str(self.state)]), \
             patch.object(simulator, "command", side_effect=self.command), contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(simulator.main(), 0)
        self.assertEqual(output.getvalue(), self.SOURCE + "\n")
        self.assertEqual(self.read()["mode"], "existing")
        self.assertEqual(self.mutations(), [])

    def test_cli_explicit_fresh_flag_and_cleanup_use_the_same_owned_record(self):
        with patch.object(sys, "argv", ["script", "prepare", "--runtime", "iOS-26-2", "--device", "iPhone 17", "--fresh", "--state", str(self.state)]), \
             patch.object(simulator, "command", side_effect=self.command), contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(simulator.main(), 0)
        self.assertEqual(output.getvalue(), self.CREATED + "\n")
        self.assertEqual(self.read()["mode"], "fresh")
        self.assertEqual(self.read()["source_simulator_state"], "Shutdown")
        with patch.object(sys, "argv", ["script", "cleanup", "--state", str(self.state)]), \
             patch.object(simulator, "command", side_effect=self.command), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(simulator.main(), 0)
        self.assertEqual(self.read()["cleanup"], "deleted")

    def test_cli_failure_emits_no_uuid_or_raw_native_error(self):
        with patch.object(sys, "argv", ["script", "prepare", "--runtime", "iOS-26-2", "--device", "iPhone 17", "--fresh", "--state", str(self.state)]), \
             patch.object(simulator, "command", side_effect=ValueError("private-path")), \
             contextlib.redirect_stdout(io.StringIO()) as output, contextlib.redirect_stderr(io.StringIO()) as error:
            self.assertEqual(simulator.main(), 1)
        self.assertEqual(output.getvalue(), "")
        self.assertNotIn("private-path", error.getvalue())
        self.assertFalse(self.state.exists())


if __name__ == "__main__":
    unittest.main()
