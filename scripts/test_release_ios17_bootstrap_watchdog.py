import ctypes
from dataclasses import replace
import io
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

import ios17_bootstrap_watchdog as watchdog
import release_ios17 as ios17


SIMULATOR = "12345678-1234-1234-1234-123456789ABC"
RUNTIME = Path("/Library/Developer/CoreSimulator/Volumes/iOS_21A342/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 17.0.simruntime/Contents/Resources/RuntimeRoot")
WORKSPACE = Path("/Users/runner/work/woow-assistant-ios/woow-assistant-ios")
OUTPUT = WORKSPACE / "build/ios17"
RECEIPT = watchdog.ServiceReceipt(SIMULATOR, 200, 1020)
ENV = {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted",
       "VALIDATION_MODE": "ios17-hosted", "IOS17_SAMPLE_BOOTSTRAP": "true",
       "GITHUB_REPOSITORY": "WOOWTECH/woow-assistant-ios", "GITHUB_WORKSPACE": str(WORKSPACE),
       "HOME": "/Users/runner", "DEVELOPER_DIR": "/Applications/Xcode_16.4.app/Contents/Developer"}
RUNNER = (Path("/Users/runner/Library/Developer/CoreSimulator/Devices") / SIMULATOR /
          "data/Containers/Bundle/Application/11111111-1111-1111-1111-111111111111/WoowAssistantUITests-Runner.app/WoowAssistantUITests-Runner")


def identities(image="xpcproxy_sim"):
    return {100: watchdog.Identity(100, 1, 501, (1000, 0), str(RUNTIME / "sbin/launchd_sim")),
            200: watchdog.Identity(200, 100, 501, (1010, 100), str(RUNTIME / "usr/libexec" / image)),
            300: watchdog.Identity(300, 100, 501, (1030, 0), str(RUNNER))}


def sample(pid=200):
    return ("Process: xpcproxy_sim [%d]\nCommand line: synthetic-private-argv\n"
            "Environment: SYNTHETIC_SECRET=synthetic-private-value\nPath: /private/secret\n"
            "Call graph:\n    151 Thread_1234: synthetic-private-thread\n"
            "    + 151 start (in dyld) + 10 [0x1]\n"
            "    +   151 __ulock_wait (in libsystem_kernel.dylib) + 8 [0x2]\n"
            "Environment: synthetic-private-value\n"
            "    + 10 invalid\"synthetic-private-value (in dyld) + 1\n"
            "Total number in stack: 151\nBinary Images:\n/private/secret\n" % pid).encode()


class GateTests(unittest.TestCase):
    def test_only_explicit_hosted_fixture_gate(self):
        selectors = ios17.TEST_SCOPES["ui-documents"]
        watchdog.validate_gate(ENV, OUTPUT, True, selectors, "Darwin")
        for key in ENV:
            with self.subTest(key=key), self.assertRaises(ValueError):
                watchdog.validate_gate(dict(ENV, **{key: "invalid"}), OUTPUT, True, selectors, "Darwin")
        for prelaunch, output, system in [(False, OUTPUT, "Darwin"), (True, Path("/tmp/result"), "Darwin"),
                                          (True, OUTPUT, "Linux")]:
            with self.subTest(prelaunch=prelaunch, output=output, system=system), self.assertRaises(ValueError):
                watchdog.validate_gate(ENV, output, prelaunch, selectors, system)

    def test_live_full_native_and_unknown_selection_fail_closed(self):
        for selectors in [[], ["WoowAssistantUITests"], ["AssistantSkillsTests"],
                          ["WoowAssistantUITests/LiveModelUITests"],
                          ["WoowAssistantUITests/SkillExecutionUITests/testFoo/extra"],
                          ["WoowAssistantUITests/UnknownUITests"],
                          ["WoowAssistantUITests/SkillExecutionUITests/../LiveModelUITests"]]:
            with self.subTest(selectors=selectors), self.assertRaises(ValueError):
                watchdog.validate_gate(ENV, OUTPUT, True, selectors, "Darwin")
        for scope in [*ios17.UI_SHARDS, *ios17.DOCUMENT_SCOPES]:
            watchdog.validate_gate(ENV, OUTPUT, True, ios17.TEST_SCOPES[scope], "Darwin")

    def test_opt_in_cli_and_workflow_preserve_default_budgets(self):
        for flags, expected in [([], False), (["--sample-test-bootstrap"], True)]:
            with patch.object(sys, "argv", ["release_ios17.py", *flags]), patch.object(ios17, "execute") as execute:
                self.assertEqual(ios17.main(), 0)
                self.assertIs(execute.call_args.kwargs["sample_bootstrap"], expected)
        source = Path(ios17.__file__).read_text()
        self.assertIn('420 if test_scope in ("all", "workspace", "ui-workspace") else 300', source)
        self.assertIn('1800 if test_scope in UI_SHARDS or test_scope in DOCUMENT_SCOPES else 4800', source)
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/release-ios.yml").read_text()
        option = workflow.split("      ios17_sample_bootstrap:\n")[1].split("\npermissions:")[0]
        self.assertIn("default: false", option)
        self.assertIn("type: boolean", option)
        self.assertIn("inputs.ios17_sample_bootstrap", next(l for l in workflow.splitlines() if l.strip().startswith("group:")))
        self.assertIn("build/ios17/bootstrap-samples/*.txt", workflow)
        self.assertNotIn("build/ios17/bootstrap-samples/\n", workflow)

    def test_diagnostic_children_do_not_inherit_credentials_or_arguments(self):
        with patch.dict(os.environ, {"TOKEN": "synthetic-secret", "SIMCTL_CHILD_SECRET": "synthetic-secret",
                                     "PATH": "synthetic-private-path", "DYLD_INSERT_LIBRARIES": "synthetic"}):
            environment = watchdog.diagnostic_environment()
        self.assertEqual(set(environment), {"PATH", "HOME", "DEVELOPER_DIR", "TMPDIR", "LANG"})
        self.assertNotIn("synthetic", json.dumps(environment))


class IdentityTests(unittest.TestCase):
    def test_public_binding_matches_native_bsdinfo_size_and_own_process(self):
        self.assertEqual(ctypes.sizeof(watchdog._BSDInfo), 136)
        if platform.system() == "Darwin":
            identity = watchdog.PublicProcessIdentity()(os.getpid())
            self.assertIsNotNone(identity)
            self.assertEqual(identity.pid, os.getpid())
            self.assertEqual(identity.uid, os.getuid())
            self.assertEqual(identity.ppid, os.getppid())
            self.assertTrue(Path(identity.path).is_absolute())
            self.assertEqual(watchdog.PublicProcessIdentity()(os.getpid()), identity)

    def owned(self, records):
        return watchdog.OwnedProcesses(SIMULATOR, RECEIPT, RUNTIME, records.get, 501)

    def test_service_receipt_allows_proxy_then_exec_without_relaunch(self):
        records = identities()
        reads = Mock(side_effect=records.get)
        owned = watchdog.OwnedProcesses(SIMULATOR, RECEIPT, RUNTIME, reads, 501)
        self.assertEqual(owned.current("daemon_early"), records[200])
        records[200] = replace(records[200], path=str(RUNTIME / "usr/libexec/testmanagerd"))
        self.assertEqual(owned.current("daemon_later"), records[200])
        self.assertTrue(all(call.args[0] in {100, 200} for call in reads.call_args_list))

    def test_wrong_uid_parent_image_runtime_or_pid_are_refused(self):
        for field, value in [("uid", 0), ("ppid", 1), ("path", "/usr/libexec/testmanagerd"),
                             ("path", str(RUNTIME / "usr/libexec/not-testmanagerd")),
                             ("path", str(RUNTIME / "../RuntimeRoot/usr/libexec/testmanagerd")),
                             ("started", (999, 0))]:
            records = identities()
            records[200] = replace(records[200], **{field: value})
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                self.owned(records)
        with self.assertRaises(ValueError):
            watchdog.OwnedProcesses(SIMULATOR, replace(RECEIPT, pid=999), RUNTIME, identities().get, 501)

    def test_other_simulator_receipt_raw_pid_and_pid_born_after_receipt_are_rejected(self):
        for receipt in (200, replace(RECEIPT, simulator="11111111-1111-1111-1111-111111111111"),
                        replace(RECEIPT, returned_at=1010)):
            with self.subTest(receipt=receipt), self.assertRaises(ValueError):
                watchdog.OwnedProcesses(SIMULATOR, receipt, RUNTIME, identities().get, 501)

    def test_service_or_manager_pid_reuse_and_exit_refused(self):
        for pid in (100, 200):
            records = identities()
            owned = self.owned(records)
            records[pid] = replace(records[pid], started=(9000, 0))
            self.assertIsNone(owned.current("daemon_early"))
            records.pop(pid)
            self.assertIsNone(owned.current("daemon_later"))

    def test_runner_must_be_exact_selected_simulator_container_and_parent(self):
        records = identities()
        owned = self.owned(records)
        original = records[300]
        self.assertEqual(owned.current("runner_bootstrap", 300), original)
        for changes in [{"path": str(RUNNER).replace(SIMULATOR, "A" * 36)}, {"ppid": 999},
                        {"path": str(RUNNER).replace("WoowAssistantUITests-Runner.app", "Other.app")},
                        {"uid": 0}, {"path": str(RUNNER).replace("/data/", "/data/../data/")},
                        {"path": "/Applications/WoowAssistantUITests-Runner.app/WoowAssistantUITests-Runner"}]:
            records[300] = replace(original, **changes)
            self.assertIsNone(owned.current("runner_bootstrap", 300))

    def test_public_runtime_inventory_exact_match_and_size_guard(self):
        runtime = {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-17-0-1", "version": "17.0.1", "buildversion": "21A342"}
        record = dict(runtime, isAvailable=True, bundlePath=str(RUNTIME.parent.parent.parent))
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "runtimes-before.json"
            path.write_text(json.dumps({"runtimes": [record]}))
            self.assertEqual(watchdog.runtime_root(folder, runtime), RUNTIME)
            for records in [[dict(record, version="17.5")], [record, record],
                            [dict(record, bundlePath="/tmp/evil.simruntime")], [dict(record, isAvailable=False)]]:
                path.write_text(json.dumps({"runtimes": records}))
                with self.assertRaises(ValueError):
                    watchdog.runtime_root(folder, runtime)
            path.write_bytes(b" " * (1024 * 1024 + 1))
            with self.assertRaises(ValueError):
                watchdog.runtime_root(folder, runtime)


class StackTests(unittest.TestCase):
    def test_only_frames_survive_no_headers_argv_env_paths_or_queue_labels(self):
        result, frames = watchdog.stack_only(sample(), 200)
        self.assertEqual(frames, 2)
        self.assertIn(b"__ulock_wait", result)
        self.assertIn(b"thread 1", result)
        for forbidden in [b"synthetic", b"/private", b"Environment", b"Command", b"Process:"]:
            self.assertNotIn(forbidden, result)

    def test_wrong_report_pid_missing_frames_invalid_encoding_and_size_fail_closed(self):
        for raw in [sample(201), b"Process: x [200]\nCall graph:\nno stack\n",
                    sample() + b"\xff", sample() + b" " * watchdog.MAX_SAMPLE_BYTES]:
            with self.subTest(size=len(raw)), self.assertRaises((ValueError, UnicodeError)):
                watchdog.stack_only(raw, 200)


class FakeChild:
    def __init__(self, clock, finish_at=None, code=0):
        self.clock, self.finish_at, self.code = clock, finish_at, code
        self.kills = 0
        self.waits = []

    def poll(self):
        return self.code if self.finish_at is not None and self.clock[0] >= self.finish_at else None

    def kill(self):
        self.kills += 1
        self.finish_at, self.code = self.clock[0], -9

    def wait(self, timeout):
        self.waits.append(timeout)
        if self.finish_at is not None and self.finish_at <= self.clock[0] + timeout:
            self.clock[0] = self.finish_at
            return self.code
        self.clock[0] += timeout
        raise subprocess.TimeoutExpired("fixed", timeout)


class BudgetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name)
        (self.output / "tests.log").touch()
        self.ticks = [0]
        self.records = identities()
        self.owned = watchdog.OwnedProcesses(SIMULATOR, RECEIPT, RUNTIME, self.records.get, 501)
        self.calls = []
        self.children = []

        def spawn(args, **kwargs):
            self.calls.append((args, kwargs))
            raw = Path(args[-1])
            raw.write_bytes(sample(int(args[1])))
            child = FakeChild(self.ticks, self.ticks[0] + 3)
            self.children.append(child)
            return child
        self.watcher = watchdog.Watchdog(self.output, self.owned, clock=lambda: self.ticks[0], spawn=spawn)

    def tick(self, now, deadline=1800):
        self.ticks[0] = now
        self.watcher.tick(deadline)

    def test_three_slots_only_fixed_public_sample_command_and_file_limit(self):
        self.tick(14)
        self.assertEqual(len(self.calls), 0)
        self.tick(15)
        self.tick(18)
        self.tick(75)
        self.tick(78)
        (self.output / "tests.log").write_text("WoowAssistantUITests-Runner[300:20] [Default] Running tests...\n")
        self.tick(90)
        self.tick(109)
        self.assertEqual(len(self.calls), 2)
        self.tick(110)
        self.tick(113)
        self.tick(1000)
        self.assertEqual(len(self.calls), 3)
        self.assertTrue(all(event["status"] == "captured" for event in self.watcher.report["attempts"]))
        for args, kwargs in self.calls:
            self.assertEqual(args[:1], ["/usr/bin/sample"])
            self.assertEqual(args[2:6], ["3", "20", "-mayDie", "-file"])
            self.assertEqual(kwargs["stdout"], subprocess.DEVNULL)
            self.assertEqual(kwargs["stderr"], subprocess.DEVNULL)
            with patch.object(watchdog.resource, "setrlimit") as limits:
                kwargs["preexec_fn"]()
                limits.assert_called_once_with(watchdog.resource.RLIMIT_FSIZE, (watchdog.MAX_SAMPLE_BYTES,) * 2)
        self.assertFalse(list(self.watcher.output.glob("*.raw")))

    def test_no_room_for_full_sample_bound_consumes_slot_without_retry(self):
        self.tick(15, 29.9)
        self.assertEqual(self.watcher.report["attempts"][0]["status"], "insufficient_remaining_budget")
        self.tick(16, 1800)
        self.assertEqual(self.calls, [])

    def test_identity_change_during_sample_discards_stack(self):
        self.tick(15)
        self.records[200] = replace(self.records[200], started=(1100, 0))
        self.tick(18)
        self.assertEqual(self.watcher.report["attempts"][0]["status"], "identity_changed_discarded")
        self.assertFalse(list(self.watcher.output.glob("*.txt")))

    def test_proxy_exec_during_sample_discarded_but_later_slot_can_capture_daemon(self):
        self.tick(15)
        self.records[200] = replace(self.records[200], path=str(RUNTIME / "usr/libexec/testmanagerd"))
        self.tick(18)
        self.assertEqual(self.watcher.report["attempts"][0]["status"], "identity_changed_discarded")
        self.tick(75)
        self.tick(78)
        self.assertEqual(self.watcher.report["attempts"][1]["status"], "captured")

    def test_actual_method_start_cancels_active_sampling_and_all_future_slots(self):
        self.tick(15)
        (self.output / "tests.log").write_text("Test Case '-[WoowAssistantUITests.SkillExecutionUITests testSynthetic]' started.\n")
        self.tick(16)
        self.tick(200)
        self.assertEqual(self.children[0].kills, 1)
        self.assertEqual(len(self.calls), 1)
        self.assertTrue(self.watcher.report["actual_test_case_started"])
        self.assertFalse(list(self.watcher.output.glob("*.raw")))

    def test_sample_command_timeout_kills_only_our_sampler_and_does_not_wait(self):
        self.tick(15)
        self.children[0].finish_at = None
        self.tick(30)
        self.assertEqual(self.children[0].kills, 1)
        self.assertEqual(self.children[0].waits, [])
        self.assertEqual(self.watcher.report["attempts"][0]["status"], "cancelled")

    def test_build_exit_stops_sampler_immediately_and_preserves_nonzero(self):
        build = FakeChild(self.ticks, 16, 65)
        spawn = Mock(return_value=build)
        result = watchdog.run_observed(["xcodebuild", "fixed"], io.BytesIO(), 60, self.watcher,
                                      clock=lambda: self.ticks[0], spawn=spawn)
        self.assertEqual(result.returncode, 65)
        self.assertEqual(spawn.call_count, 1)
        self.assertEqual(build.kills, 0)
        self.assertEqual(self.children[0].kills, 1)
        self.assertEqual(self.ticks[0], 16)

    def test_original_deadline_is_not_extended_for_sampling_or_cleanup(self):
        build = FakeChild(self.ticks)
        spawn = Mock(return_value=build)
        with self.assertRaises(subprocess.TimeoutExpired):
            watchdog.run_observed(["xcodebuild", "fixed"], io.BytesIO(), 31, self.watcher,
                                  clock=lambda: self.ticks[0], spawn=spawn)
        self.assertEqual(spawn.call_count, 1)
        self.assertEqual(build.kills, 1)
        self.assertEqual(self.ticks[0], 31)
        self.assertEqual(self.watcher.report["status"], "stopped")

    def test_diagnostic_failure_preserves_test_verdict_and_stops_once(self):
        build = FakeChild(self.ticks, 1, 65)
        with patch.object(self.watcher, "tick", side_effect=OSError("synthetic-secret")) as tick:
            result = watchdog.run_observed(["xcodebuild"], io.BytesIO(), 31, self.watcher,
                                          clock=lambda: self.ticks[0], spawn=lambda *a, **k: build)
        self.assertEqual(tick.call_count, 1)
        self.assertEqual(result.returncode, 65)
        self.assertNotIn("synthetic-secret", json.dumps(self.watcher.report))


if __name__ == "__main__":
    unittest.main()
