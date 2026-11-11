"""Opt-in diagnostics for a fresh, non-Live GitHub-hosted iOS 17 fixture.

No readiness claim, retry, service restart, or target signal. The service PID
comes ONLY from this invocation's public `simctl spawn UUID launchctl
kickstart -p user/UID/com.apple.testmanagerd`. libproc verifies its identity,
parent and executable before/after sampling (including the xpcproxy phase).
The caller retains the original xcodebuild deadline and acceptance checks.
"""
import ctypes
from dataclasses import dataclass
import json
import os
from pathlib import Path
import platform
import re
import resource
import subprocess
import time
import uuid


MAX_SAMPLE_BYTES = 2 * 1024 * 1024
MAX_SAMPLES = 3
SAMPLE_SECONDS = 3
SAMPLE_COMMAND_SECONDS = 15
POLL_SECONDS = 0.2
FIXTURE_CLASSES = frozenset({
    "WoowAssistantUITests", "SelfConfigurationUITests", "ChatStreamingUITests", "AppLanguageUITests", "AppLanguagePhase2UITests", "ConversationArchiveUITests", "BrowserWorkspaceUITests",
    "BrowserLoginUITests", "BrowserSiteModesUITests", "BrowserSearchUITests", "BrowserInteractionUITests", "BrowserUploadUITests",
    "BrowserLearningUITests", "MultiSourceResearchUITests", "MemoryUITests",
    "MemoryRaceUITests", "UserProfileUITests", "UserProfileToolUITests",
    "MemoryToolUITests", "SkillCatalogUITests", "SkillAuthoringUITests",
    "TranscriptUITests", "SkillExecutionUITests", "SkillWorkerSettingsUITests", "SkillPDFAssemblyMultiFileUITests", "ChatPDFAttachmentUITests",
    "BrowserDownloadedPDFUITests", "SkillPDFCapabilityUITests",
    "MCPConversationUITests", "MCPLearningUITests", "NotificationUITests", "NotificationApprovalUITests",
})


def validate_gate(environment, output, prelaunch, selectors, system=None):
    """Explicit hosted/fixture/path gate, before any process observation."""
    workspace = Path(environment.get("GITHUB_WORKSPACE", "/invalid"))
    if (not prelaunch or (system or platform.system()) != "Darwin"
            or environment.get("GITHUB_ACTIONS") != "true"
            or environment.get("RUNNER_ENVIRONMENT") != "github-hosted"
            or environment.get("VALIDATION_MODE") != "ios17-hosted"
            or environment.get("IOS17_SAMPLE_BOOTSTRAP") != "true"
            or environment.get("GITHUB_REPOSITORY") != "WOOWTECH/woow-assistant-ios"
            or workspace != Path("/Users/runner/work/woow-assistant-ios/woow-assistant-ios")
            or Path(output).resolve() != workspace / "build/ios17"
            or environment.get("HOME") != "/Users/runner"
            or environment.get("DEVELOPER_DIR") != "/Applications/Xcode_16.4.app/Contents/Developer"
            or not selectors):
        raise ValueError("bootstrap_sampling_gate_rejected")
    for selector in selectors:
        parts = selector.split("/")
        if (len(parts) not in (2, 3) or parts[0] != "WoowAssistantUITests"
                or parts[1] not in FIXTURE_CLASSES
                or (len(parts) == 3 and not re.fullmatch(r"test[A-Za-z0-9_]+", parts[2]))):
            raise ValueError("bootstrap_sampling_scope_rejected")


def diagnostic_environment():
    # Never inherit secrets, SIMCTL_CHILD_*, DYLD_*, or custom PATH entries.
    return {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/Users/runner",
            "DEVELOPER_DIR": "/Applications/Xcode_16.4.app/Contents/Developer",
            "TMPDIR": "/tmp", "LANG": "C"}


class _BSDInfo(ctypes.Structure):
    # Public sys/proc_info.h: PROC_PIDTBSDINFO (3), macOS 10.5+.
    _fields_ = [(name, ctypes.c_uint32) for name in (
        "flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid",
        "rgid", "svuid", "svgid", "reserved")]
    _fields_ += [("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in (
        "nfiles", "pgid", "pjobc", "tdev", "tpgid")]
    _fields_ += [("nice", ctypes.c_int32), ("seconds", ctypes.c_uint64),
                 ("microseconds", ctypes.c_uint64)]


@dataclass(frozen=True)
class Identity:
    pid: int
    ppid: int
    uid: int
    started: tuple
    path: str

    def same_process(self, other):
        return (other is not None and (self.pid, self.ppid, self.uid, self.started)
                == (other.pid, other.ppid, other.uid, other.started))


class PublicProcessIdentity:
    """No ps argv/env, private APIs, task memory, or process enumeration."""
    def __init__(self):
        self.lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                         ctypes.c_void_p, ctypes.c_int]
        self.lib.proc_pidinfo.restype = ctypes.c_int
        self.lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.lib.proc_pidpath.restype = ctypes.c_int

    def __call__(self, pid):
        if type(pid) is not int or not 1 < pid <= 2_147_483_647:
            return None
        before, after = _BSDInfo(), _BSDInfo()
        size = ctypes.sizeof(before)
        if self.lib.proc_pidinfo(pid, 3, 0, ctypes.byref(before), size) != size:
            return None
        path = ctypes.create_string_buffer(4096)
        length = self.lib.proc_pidpath(pid, path, len(path))
        if not 0 < length < len(path):
            return None
        if self.lib.proc_pidinfo(pid, 3, 0, ctypes.byref(after), size) != size:
            return None
        fields = lambda info: (info.pid, info.ppid, info.uid, info.seconds, info.microseconds)
        if fields(before) != fields(after) or after.pid != pid or after.seconds == 0:
            return None
        try:
            executable = path.value.decode("utf-8", errors="strict")
        except UnicodeError:
            return None
        if not executable.startswith("/") or ".." in Path(executable).parts:
            return None
        return Identity(pid, after.ppid, after.uid,
                        (after.seconds, after.microseconds), executable)


@dataclass(frozen=True)
class ServiceReceipt:
    # Created only from kickstart -p's result in the selected simulator's
    # user/UID/com.apple.testmanagerd namespace, never a process-name search.
    simulator: str
    pid: int
    returned_at: float


def runtime_root(output, runtime):
    """Use the exact public simctl inventory already obtained by the caller."""
    inventory = Path(output) / "runtimes-after.json"
    if not inventory.exists():
        inventory = Path(output) / "runtimes-before.json"
    if inventory.stat().st_size > 1024 * 1024:
        raise ValueError("runtime_identity_unavailable")
    records = json.loads(inventory.read_text())["runtimes"]
    selected = [r for r in records if all(r.get(k) == runtime.get(k)
                for k in ("identifier", "version", "buildversion")) and r.get("isAvailable") is True]
    if len(selected) != 1 or not str(runtime.get("version", "")).startswith("17."):
        raise ValueError("runtime_identity_unavailable")
    bundle = Path(selected[0].get("bundlePath") or "/invalid")
    trusted = (Path("/Library/Developer/CoreSimulator"),
               Path("/Applications/Xcode_16.4.app/Contents/Developer"))
    if (".." in bundle.parts or bundle.suffix != ".simruntime"
            or not any(base in bundle.parents for base in trusted)):
        raise ValueError("runtime_identity_unavailable")
    resolved = bundle.resolve()
    if not any(base in resolved.parents for base in trusted):
        raise ValueError("runtime_identity_unavailable")
    return resolved / "Contents/Resources/RuntimeRoot"


class OwnedProcesses:
    def __init__(self, simulator, receipt, runtime, read_identity, uid):
        self.simulator = str(uuid.UUID(simulator)).upper()
        if (not isinstance(receipt, ServiceReceipt)
                or str(uuid.UUID(receipt.simulator)).upper() != self.simulator):
            raise ValueError("service_namespace_mismatch")
        self.root = Path(runtime)
        self.read = read_identity
        self.uid = uid
        self.daemon = read_identity(receipt.pid)
        if (self.daemon is None or self.daemon.started[0] + self.daemon.started[1] / 1_000_000 > receipt.returned_at):
            raise ValueError("service_identity_unavailable")
        self.manager = read_identity(self.daemon.ppid)
        if (self.manager is None or self.manager.uid != uid
                or self.manager.path != str(self.root / "sbin/launchd_sim")
                or not self._daemon_valid(self.daemon)):
            raise ValueError("service_identity_unavailable")

    def _daemon_valid(self, identity):
        paths = {str(self.root / "usr/libexec/xpcproxy_sim"),
                 str(self.root / "usr/libexec/testmanagerd")}
        return (identity is not None and identity.uid == self.uid
                and identity.ppid == self.manager.pid and identity.path in paths
                and identity.started >= self.manager.started)

    def current(self, role, runner_pid=None):
        if self.read(self.manager.pid) != self.manager:
            return None
        if role.startswith("daemon"):
            current = self.read(self.daemon.pid)
            if self.daemon.same_process(current) and self._daemon_valid(current):
                # exec xpcproxy -> testmanagerd retains PID/birth identity.
                return current
            return None
        current = self.read(runner_pid)
        if (current is None or current.uid != self.uid or current.ppid != self.manager.pid
                or current.started < self.manager.started):
            return None
        root = Path("/Users/runner/Library/Developer/CoreSimulator/Devices") / self.simulator
        try:
            parts = Path(current.path).relative_to(root).parts
        except ValueError:
            return None
        if (len(parts) != 7 or parts[:4] != ("data", "Containers", "Bundle", "Application")
                or not re.fullmatch(r"[0-9A-Fa-f-]{36}", parts[4])
                or parts[5:] != ("WoowAssistantUITests-Runner.app", "WoowAssistantUITests-Runner")):
            return None
        return current


def stack_only(raw, pid):
    """Retain numeric thread ordinals/system symbol frames, never headers/argv/env.

    sample is not a memory dump. Still discard its headers, thread/queue labels,
    paths, binary-image table, unsupported lines and quoted/dynamic strings.
    """
    if len(raw) > MAX_SAMPLE_BYTES:
        raise ValueError("sample_size_limit")
    text = raw.decode("utf-8", errors="strict")
    if not re.search(r"^Process:\s+[^\n]*\[" + str(pid) + r"\]\s*$", text, re.M):
        raise ValueError("sample_identity_mismatch")
    if "Call graph:\n" not in text:
        raise ValueError("sample_stack_unavailable")
    graph = text.split("Call graph:\n", 1)[1].split("\nTotal number", 1)[0].split("\nBinary Images:", 1)[0]
    frames, threads, result = 0, 0, []
    for line in graph.splitlines():
        if re.fullmatch(r"\s*\d+ Thread_[^\n]+", line):
            threads += 1
            result.append("thread %d" % threads)
            continue
        match = re.fullmatch(r"([ +!:|]*)([0-9]+) ([^\n]+?) \(in ([A-Za-z0-9_.+-]+)\)([^\n]*)", line)
        if not match or len(match[1]) > 256:
            continue
        symbol = match[3]
        if (len(symbol) > 400 or not re.fullmatch(r"[A-Za-z0-9_.$:+*?~<>,()\[\] -]+", symbol)
                or any(word in symbol.lower() for word in ("environment:", "command line:", "argv="))):
            continue
        result.append("%s%s %s (in %s)" % (match[1], match[2], symbol, match[4]))
        frames += 1
    if not frames:
        raise ValueError("sample_stack_unavailable")
    return ("\n".join(result) + "\n").encode(), frames


class LogProgress:
    """Bounded incremental scan of our own build log; never copy log text out."""
    def __init__(self, path):
        self.path = Path(path)
        self.offset = 0
        self.tail = b""
        self.runner_pid = None
        self.runner_seen_at = None
        self.case_started = False

    def update(self, now):
        with self.path.open("rb") as source:
            source.seek(self.offset)
            data = source.read(256 * 1024)
            self.offset = source.tell()
        content = self.tail + data
        if re.search(rb"Test Case '-\[(?:\w+\.)?\w+ test\w+\]' started\.", content):
            self.case_started = True
        match = re.search(rb"WoowAssistantUITests-Runner\[([1-9][0-9]{0,9}):[0-9]+\][^\r\n]{0,100}\bRunning tests\.\.\.", content)
        if match and self.runner_pid is None:
            self.runner_pid = int(match[1])
            self.runner_seen_at = now
        self.tail = content[-1024:]


def _sample_limits():
    # The runner is single-threaded; preexec_fn is not used from a thread.
    resource.setrlimit(resource.RLIMIT_FSIZE, (MAX_SAMPLE_BYTES, MAX_SAMPLE_BYTES))


class Watchdog:
    def __init__(self, output, owned, *, clock=time.monotonic, spawn=subprocess.Popen):
        self.output = Path(output) / "bootstrap-samples"
        self.output.mkdir(mode=0o700)
        self.owned, self.clock, self.spawn = owned, clock, spawn
        self.started = clock()
        self.progress = LogProgress(Path(output) / "tests.log")
        self.pending = [("daemon_early", self.started + 15), ("daemon_later", self.started + 75)]
        self.runner_scheduled = False
        self.active = None
        self.report = {"status": "observing", "handshake_verified": False,
                       "max_samples": MAX_SAMPLES, "sample_seconds": SAMPLE_SECONDS,
                       "sample_command_seconds": SAMPLE_COMMAND_SECONDS,
                       "sample_byte_limit": MAX_SAMPLE_BYTES, "attempts": [],
                       "actual_test_case_started": False}
        self.save()

    def save(self):
        # All fields are fixed codes/counts; never persist executable paths,
        # sample headers, environment, process arguments or command errors.
        (self.output / "report.json").write_text(json.dumps(self.report, indent=2) + "\n")

    def _finish_sample(self, cancelled=False):
        child, identity, event, raw, expires = self.active
        if cancelled and child.poll() is None:
            child.kill()  # ONLY the sample child we created, never the target.
        code = child.poll()
        if cancelled:
            event["status"] = "cancelled"
        elif code != 0:
            event["status"] = "sample_failed"
        elif self.owned.current(event["role"], identity.pid) != identity:
            event["status"] = "identity_changed_discarded"
        else:
            try:
                if raw.stat().st_size > MAX_SAMPLE_BYTES:
                    raise ValueError("sample_size_limit")
                stack, count = stack_only(raw.read_bytes(), identity.pid)
                (self.output / (event["role"] + ".txt")).write_bytes(stack)
                event.update(status="captured", frames=count, bytes=len(stack))
            except (OSError, ValueError, UnicodeError):
                event["status"] = "sample_unusable"
        raw.unlink(missing_ok=True)
        self.active = None
        self.save()

    def tick(self, deadline):
        now = self.clock()
        self.progress.update(now)
        self.report["actual_test_case_started"] = self.progress.case_started
        if self.progress.case_started:
            self.pending.clear()
            if self.active:
                self._finish_sample(cancelled=True)
            return
        if self.active:
            if self.active[0].poll() is not None:
                self._finish_sample()
            elif now >= self.active[4]:
                self._finish_sample(cancelled=True)
        if not self.runner_scheduled and self.progress.runner_seen_at is not None:
            self.pending.append(("runner_bootstrap", self.progress.runner_seen_at + 20))
            self.pending.sort(key=lambda slot: slot[1])
            self.runner_scheduled = True
        if self.active or not self.pending or len(self.report["attempts"]) >= MAX_SAMPLES:
            return
        role, due = self.pending[0]
        if now < due:
            return
        self.pending.pop(0)  # Every slot is consumed once, even on refusal/failure.
        event = {"role": role, "elapsed_seconds": round(now - self.started, 3)}
        self.report["attempts"].append(event)
        # Reserve the entire command bound inside the caller's original budget.
        if deadline - now < SAMPLE_COMMAND_SECONDS:
            event["status"] = "insufficient_remaining_budget"
        else:
            identity = self.owned.current(role, self.progress.runner_pid)
            if identity is None:
                event["status"] = "identity_unverified"
            else:
                event["image"] = Path(identity.path).name
                raw = self.output / (role + ".raw")
                try:
                    child = self.spawn(["/usr/bin/sample", str(identity.pid), str(SAMPLE_SECONDS), "20",
                                        "-mayDie", "-file", str(raw)], stdin=subprocess.DEVNULL,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                       env=diagnostic_environment(), preexec_fn=_sample_limits)
                    event["status"] = "sampling"
                    self.active = (child, identity, event, raw, now + SAMPLE_COMMAND_SECONDS)
                except OSError:
                    event["status"] = "sample_unavailable"
        self.save()

    def stop(self):
        self.pending.clear()
        if self.active:
            self._finish_sample(cancelled=True)
        self.report["status"] = "stopped"
        self.save()


def run_observed(arguments, log, timeout, watcher, *, clock=time.monotonic,
                 spawn=subprocess.Popen):
    """One xcodebuild; no diagnostic wait is appended to its original budget.

    Popen.wait's short timeout is solely process monitoring, not a readiness
    delay. At exit/timeout the sample child is killed without a blocking join;
    Popen retains/reaps it on subsequent subprocess activity. No target signal.
    """
    deadline = clock() + timeout
    child = None
    try:
        child = spawn(arguments, stdout=log, stderr=subprocess.STDOUT)
        while True:
            code = child.poll()
            if code is not None:
                return subprocess.CompletedProcess(arguments, code)
            remaining = deadline - clock()
            if remaining <= 0:
                child.kill()  # Same xcodebuild timeout semantics as subprocess.run.
                raise subprocess.TimeoutExpired(arguments, timeout)
            if watcher is not None:
                try:
                    watcher.tick(deadline)
                    if watcher.progress.case_started:
                        watcher.stop()
                        watcher = None
                except Exception:
                    # Diagnostics can fail closed; never replace XCTest's verdict.
                    watcher.report["diagnostic_error"] = True
                    try:
                        watcher.stop()
                    except Exception:
                        pass
                    watcher = None
            try:
                child.wait(timeout=min(POLL_SECONDS, max(0, deadline - clock())))
            except subprocess.TimeoutExpired:
                pass
    finally:
        if watcher is not None:
            try:
                watcher.stop()
            except Exception:
                pass

