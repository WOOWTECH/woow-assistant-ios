#!/usr/bin/env python3
"""Run the existing XCTest scheme on an exact iOS 17 simulator runtime.

No fallback to iOS 18/26. --download uses Apple's supported installer only.
A disposable simulator is created and deleted; physical devices are untouched.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
import platform
import plistlib
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid

from release_ios import ReleaseError, ReleaseToolError, generate_project, run, version, verify_settings

RUNTIME_INVENTORY_TIMEOUT_SECONDS = 120
RUNTIME_INVENTORY_MAX_ATTEMPTS = 2


class RuntimeInventoryError(ReleaseError):
    """Only fixed, public diagnostics for the bounded runtime inventory call."""
    def __init__(self, error, elapsed, attempts):
        super().__init__(str(error))
        self.diagnostic = {
            "category": error.category,
            "operation": "simulator_runtime_inventory",
            "elapsed_seconds": round(max(0.0, elapsed), 3),
            "timeout_seconds": RUNTIME_INVENTORY_TIMEOUT_SECONDS,
            "attempts": attempts,
            "max_attempts": RUNTIME_INVENTORY_MAX_ATTEMPTS,
        }

# This partition, unlike the legacy focused scopes below, owns every non-Live
# UI class exactly once. Keep class selectors so new methods cannot be omitted.
UI_SHARDS = {
    "ui-startup": ["WoowAssistantUITests", "SelfConfigurationUITests", "ChatStreamingUITests"],
    "ui-language": ["AppLanguageUITests", "AppLanguagePhase2UITests"],
    "ui-notifications": ["NotificationUITests", "NotificationApprovalUITests"],
    "ui-archive": ["ConversationArchiveUITests"],
    "ui-workspace": ["BrowserWorkspaceUITests", "BrowserLoginUITests", "BrowserSiteModesUITests", "BrowserSearchUITests"],
    "ui-browser": ["BrowserInteractionUITests", "BrowserUploadUITests"],
    "ui-learning": ["BrowserLearningUITests", "MultiSourceResearchUITests"],
    "ui-memory": ["MemoryUITests", "MemoryRaceUITests"],
    "ui-profile": ["UserProfileUITests", "UserProfileToolUITests"],
    "ui-memory-tools": ["MemoryToolUITests"],
    "ui-skills": ["SkillCatalogUITests", "SkillAuthoringUITests", "TranscriptUITests"],
    "ui-documents": ["SkillExecutionUITests", "SkillWorkerSettingsUITests", "SkillPDFAssemblyMultiFileUITests", "ChatPDFAttachmentUITests"],
    "ui-pdf-capability": ["SkillPDFCapabilityUITests"],
    "ui-download-pdf": ["BrowserDownloadedPDFUITests"],
    "ui-mcp": ["MCPConversationUITests", "MCPLearningUITests"],
}
LIVE_UI_CLASSES = {"LiveMCPUITests", "LiveMCPConversationUITests", "LiveModelUITests", "LiveTranscriptUITests",
                   "LiveDocumentQueryUITests", "LiveSourceDiscoveryUITests"}

# Focused selections within ui-documents, not additional partition owners.
# Their exact union is checked against discovered Swift methods at preflight.
DOCUMENT_SCOPES = {
    "documents-read": [
        "WoowAssistantUITests/SkillExecutionUITests/testNativeFilesPDFNeedsBothApprovalsAndReturnsActualText",
        "WoowAssistantUITests/SkillExecutionUITests/testCoordinatedFixtureCreationNativePDFNeedsBothApprovalsAndReturnsActualText",
        "WoowAssistantUITests/SkillExecutionUITests/testUIKitOpenInPlaceCoordinatedPDFNeedsBothApprovalsAndReturnsActualText",
        "WoowAssistantUITests/SkillExecutionUITests/testUIKitImportCopyCoordinatedPDFNeedsBothApprovalsAndReturnsActualText",
        "WoowAssistantUITests/SkillExecutionUITests/testUserChosenPDFImportCopyNeedsBothApprovalsAndReturnsActualText",
        "WoowAssistantUITests/SkillExecutionUITests/testNativePickerCancellationDoesNotReadOrExtract",
    ],
    "documents-output": [
        "WoowAssistantUITests/SkillExecutionUITests/testRefusingFirstStepDoesNotReadOrExtract",
        "WoowAssistantUITests/SkillExecutionUITests/testRefusingSecondStepKeepsExtractionUnauthorized",
        "WoowAssistantUITests/SkillExecutionUITests/testNativeExportCancellationPreservesResultAndAllowsRetry",
        "WoowAssistantUITests/SkillExecutionUITests/testNativeExportSavesTextToChosenLocalFolder",
        "WoowAssistantUITests/SkillExecutionUITests/testNativePDFAssemblyReviewsReversedPagesAndExportCancellationPreservesResult",
        "WoowAssistantUITests/SkillExecutionUITests/testUIKitOpenPDFAssemblyReviewsReversedPagesAndExportCancellationPreservesResult",
        "WoowAssistantUITests/SkillExecutionUITests/testUserChosenPDFImportCopyAssemblyReviewsReversedPagesAndExportCancellationPreservesResult",
        "WoowAssistantUITests/SkillPDFAssemblyMultiFileUITests/testUserChosenCopyAddsTwoDistinctPDFsAndInterleavesApprovedPages",
        "WoowAssistantUITests/SkillPDFAssemblyMultiFileUITests/testDirectoryCoordinatedFixtureCopyAddsTwoDistinctPDFsAndInterleavesApprovedPages",
        "WoowAssistantUITests/SkillWorkerSettingsUITests/testDedicatedWorkerSettingsPersistWithoutSelectingOrReadingAFile",
    ],
    "documents-chat": [
        "WoowAssistantUITests/ChatPDFAttachmentUITests/testNativePDFApprovalsCitationsArchiveRelaunchOpenAndDelete",
        "WoowAssistantUITests/ChatPDFAttachmentUITests/testReadApprovalThenRemoveNeverExtractsOrSubmitsAndRetainsDraft",
        "WoowAssistantUITests/ChatPDFAttachmentUITests/testCancelActualQueryKeepsQuestionAndSourceWithoutCompletedArchive",
    ],
}

TEST_SCOPES = {
    "all": [],
    "core": ["AssistantDomainTests", "AssistantModelsTests", "AssistantMCPTests", "AssistantMemoryTests", "AssistantSkillsTests", "AssistantPersistenceTests", "AssistantBrowserIntegrationTests"],
    "workspace": ["AssistantDomainTests/BrowserLibraryTests", "AssistantDomainTests/BrowserPolicyTests", "AssistantDomainTests/BrowserNavigationIntentTests", "AssistantBrowserIntegrationTests", "WoowAssistantUITests/BrowserWorkspaceUITests", "WoowAssistantUITests/BrowserLoginUITests", "WoowAssistantUITests/BrowserSiteModesUITests", "WoowAssistantUITests/BrowserSearchUITests"],
    "files": ["AssistantSkillsTests", "AssistantDomainTests/BrowserDownloadTests", "AssistantDomainTests/BrowserNavigationIntentTests", "AssistantBrowserIntegrationTests", "WoowAssistantUITests/BrowserUploadUITests", "WoowAssistantUITests/SkillExecutionUITests"],
    "parity": ["AssistantMCPTests", "AssistantSkillsTests", "AssistantDomainTests", "AssistantBrowserIntegrationTests", "WoowAssistantUITests/MCPConversationUITests", "WoowAssistantUITests/BrowserInteractionUITests", "WoowAssistantUITests/BrowserLearningUITests", "WoowAssistantUITests/SkillCatalogUITests", "WoowAssistantUITests/MemoryUITests", "WoowAssistantUITests/MemoryRaceUITests"],
    "startup": ["WoowAssistantUITests/WoowAssistantUITests"],
    "startup-smoke": ["WoowAssistantUITests/WoowAssistantUITests/testEverySectionIsReachableAndPhoneControlIsExcluded"],
    "picker-user-copy": ["WoowAssistantUITests/SkillExecutionUITests/testUserChosenPDFImportCopyNeedsBothApprovalsAndReturnsActualText"],
    "pdf-assembly": ["WoowAssistantUITests/SkillExecutionUITests/testNativePDFAssemblyReviewsReversedPagesAndExportCancellationPreservesResult"],
    "pdf-assembly-uikit": ["WoowAssistantUITests/SkillExecutionUITests/testUIKitOpenPDFAssemblyReviewsReversedPagesAndExportCancellationPreservesResult"],
    "pdf-assembly-copy": ["WoowAssistantUITests/SkillExecutionUITests/testUserChosenPDFImportCopyAssemblyReviewsReversedPagesAndExportCancellationPreservesResult"],
    "pdf-assembly-multi": ["WoowAssistantUITests/SkillPDFAssemblyMultiFileUITests/testUserChosenCopyAddsTwoDistinctPDFsAndInterleavesApprovedPages"],
    "pdf-pair-coordinated": ["WoowAssistantUITests/SkillPDFAssemblyMultiFileUITests/testDirectoryCoordinatedFixtureCopyAddsTwoDistinctPDFsAndInterleavesApprovedPages"],
    "profile-tool": ["WoowAssistantUITests/UserProfileToolUITests"],
    "memory-tools": ["WoowAssistantUITests/MemoryToolUITests"],
    **DOCUMENT_SCOPES,
    **{scope: ["WoowAssistantUITests/" + name for name in classes]
       for scope, classes in UI_SHARDS.items()},
}


def ui_inventory(root, shards=None):
    """Fail closed on unassigned/duplicate classes and unsupported test layout.

    The UI target uses one XCTestCase class per same-named Swift file, with
    zero-argument test methods. Extensions/inherited test classes require an
    explicit inventory update instead of silently disappearing from coverage.
    """
    shards = UI_SHARDS if shards is None else shards
    classes = {}
    # Mask literals/comments before scanning declarations (including embedded
    # HTML/JS and Swift raw/multiline strings in the local HTTP fixtures).
    ignored = re.compile(r'//[^\n]*|/\*.*?\*/|(?P<raw>\#*)""".*?"""(?P=raw)|'
                         r'(?P<quote>\#*)"(?:\\.|[^"\\])*"(?P=quote)', re.S)
    for path in sorted((root / "Tests/WoowAssistantUITests").rglob("*.swift")):
        source = ignored.sub(" ", path.read_text())
        names = re.findall(r'\bclass\s+(\w+)\s*:\s*XCTestCase\b', source)
        methods = re.findall(r'\bfunc\s+(test\w+)\s*\(', source)
        zero_argument = re.findall(r'\bfunc\s+(test\w+)\s*\(\s*\)', source)
        if not names and not methods:
            continue
        if (names != [path.stem] or not methods or methods != zero_argument
                or len(set(methods)) != len(methods) or path.stem in classes
                or re.search(r'\bextension\s+' + re.escape(path.stem) + r'\b', source)):
            raise ReleaseError("UI inventory 不支援此測試宣告，請明確更新清單：" + path.name)
        classes[path.stem] = ["WoowAssistantUITests/" + path.stem + "/" + m for m in sorted(methods)]
    if not classes or not LIVE_UI_CLASSES.issubset(classes):
        raise ReleaseError("UI inventory 缺少測試來源或已知 Live 類別。")
    owners = {}
    for scope, names in shards.items():
        if not scope.startswith("ui-") or not names:
            raise ReleaseError("UI 分片必須有名稱與測試類別。")
        for name in names:
            if name in owners or name in LIVE_UI_CLASSES or name not in classes:
                raise ReleaseError("UI 分片有重複、Live 或不存在的類別：" + name)
            owners[name] = scope
    missing = set(classes) - LIVE_UI_CLASSES - owners.keys()
    if missing:
        raise ReleaseError("UI 分片未涵蓋類別：" + ", ".join(sorted(missing)))
    result = {"schema_version": 1,
              "shards": {scope: {"classes": names,
                                  "tests": sorted(t for name in names for t in classes[name])}
                         for scope, names in shards.items()},
              "live_tests_excluded": sorted(t for name in LIVE_UI_CLASSES for t in classes[name])}
    result["non_live_test_count"] = sum(len(s["tests"]) for s in result["shards"].values())
    if "ui-documents" in result["shards"]:
        result["document_focused_scopes"] = validate_document_scopes(result)
    result["inventory_sha256"] = hashlib.sha256(json.dumps(result, sort_keys=True).encode()).hexdigest()
    return result


def validate_document_scopes(catalog, scopes=None):
    """Require exact disjoint method coverage; equal counts are insufficient."""
    names = ("documents-read", "documents-output", "documents-chat")
    scopes = {name: TEST_SCOPES[name] for name in names} if scopes is None else scopes
    expected = catalog["shards"]["ui-documents"]["tests"]
    if set(scopes) != set(names) or not expected or len(expected) != len(set(expected)):
        raise ReleaseError("PDF focused scopes 清單格式不符。")
    selected = []
    for name in names:
        methods = scopes[name]
        if (not methods or len(methods) != len(set(methods)) or any(
                re.fullmatch(r"WoowAssistantUITests/\w+/test\w+", method) is None for method in methods)):
            raise ReleaseError("PDF focused scope 必須列出互不重複的完整測試方法：" + name)
        selected.extend(methods)
    if len(selected) != len(set(selected)):
        raise ReleaseError("PDF focused scopes 不能重疊。")
    if set(selected) != set(expected):
        raise ReleaseError("PDF focused scopes 聯集必須精確等於 ui-documents 的實際方法清單；請歸屬新增或更名的測試。")
    return {name: sorted(scopes[name]) for name in names}


def selected_ui_tests(catalog, scope):
    tests = sorted(t for shard in catalog["shards"].values() for t in shard["tests"])
    tests += catalog["live_tests_excluded"]
    if scope == "all":
        return sorted(tests)
    return sorted(t for t in tests if any(t == selector or t.startswith(selector + "/")
                                         for selector in TEST_SCOPES[scope]))


def test_completion(summary, log_path, expected_ui, ui_only):
    """Require summary success AND each selected UI method's actual completion.

    Started-only, duplicate attempts, skipped cases, expected failures and an
    empty result cannot become acceptance evidence merely because exit == 0.
    Unknown log/summary formats fail closed, retaining the original artifacts.
    """
    keys = ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures")
    counts = {key: summary.get(key) for key in keys}
    counts_valid = all(type(v) is int and v >= 0 for v in counts.values())
    complete = (counts_valid and summary.get("result") == "Passed"
                and counts["passedTests"] > 0
                and counts["totalTestCount"] == counts["passedTests"]
                and all(counts[k] == 0 for k in ("failedTests", "skippedTests", "expectedFailures")))
    completions = {}
    pattern = re.compile(r"Test Case '-\[WoowAssistantUITests\.(\w+) (test\w+)\]' (passed|failed|skipped) \(")
    with log_path.open(errors="replace") as log:
        for line in log:
            match = pattern.search(line)
            if match:
                name, method, outcome = match.groups()
                completions.setdefault("WoowAssistantUITests/" + name + "/" + method, []).append(outcome)
    missing = sorted(set(expected_ui) - completions.keys())
    unexpected = sorted(completions.keys() - set(expected_ui))
    incomplete = sorted(t for t in expected_ui if t in completions and completions[t] != ["passed"])
    complete = bool(complete and not missing and not unexpected and not incomplete
                    and (not ui_only or counts["totalTestCount"] == len(expected_ui)))
    return {"verified": complete, "counts": counts, "result": summary.get("result"),
            "expected_ui_count": len(expected_ui), "completed_ui_count": len(completions),
            "missing_ui_tests": missing, "unexpected_ui_tests": unexpected,
            "nonpassing_or_repeated_ui_tests": incomplete}


def select_runtime(payload, requested):
    if version(requested)[0] != 17:
        raise ReleaseError("此驗證路徑只接受 iOS 17.x。")
    matches = [item for item in payload.get("runtimes", [])
               if item.get("identifier", "").startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
               and item.get("isAvailable") is True
               and version(item.get("version", "0.0")) == version(requested)]
    if len(matches) != 1:
        raise ReleaseError("找不到唯一、可用的指定 iOS 17 runtime；不會改用其他系統版本。")
    return {key: matches[0].get(key) for key in ("identifier", "version", "buildversion")}


def inventory(output, name):
    started = time.monotonic()
    for attempt in range(1, RUNTIME_INVENTORY_MAX_ATTEMPTS + 1):
        try:
            data = run(["xcrun", "simctl", "list", "runtimes", "--json"], "取得 Simulator runtime 清單",
                       timeout=RUNTIME_INVENTORY_TIMEOUT_SECONDS)
            break
        except ReleaseToolError as error:
            if error.category == "timeout" and attempt < RUNTIME_INVENTORY_MAX_ATTEMPTS:
                continue
            raise RuntimeInventoryError(error, time.monotonic() - started, attempt) from None
    payload = json.loads(data)
    # Public OS/install-path metadata, not personal device names or UDIDs.
    metadata = {"runtimes": [{key: r.get(key) for key in
                ("identifier", "version", "buildversion", "isAvailable", "availabilityError", "bundlePath")}
                for r in payload.get("runtimes", [])]}
    (output / name).write_text(json.dumps(metadata, indent=2) + "\n")
    return payload


def ensure_runtime(output, requested, download, progress=None):
    payload = inventory(output, "runtimes-before.json")
    try:
        return select_runtime(payload, requested)
    except ReleaseError:
        if not download:
            raise ReleaseError("缺少指定 runtime。請預裝後重試，或在 hosted runner 使用 --download。") from None
    # Keep the actual installer failure as evidence; these arguments contain no secrets.
    if progress:
        progress("downloading_runtime")
    with (output / "runtime-download.log").open("wb") as log:
        try:
            completed = subprocess.run(["xcodebuild", "-downloadPlatform", "iOS", "-buildVersion", requested],
                                       stdout=log, stderr=subprocess.STDOUT, timeout=1200)
            (output / "runtime-download-status.json").write_text(json.dumps({"exit_code": completed.returncode}) + "\n")
        except subprocess.TimeoutExpired:
            (output / "runtime-download-status.json").write_text('{"timed_out": true}\n')
    if progress:
        progress("checking_installed_runtime")
    payload = inventory(output, "runtimes-after.json")
    try:
        return select_runtime(payload, requested)
    except ReleaseError:
        raise ReleaseError("指定 iOS 17 runtime 下載／安裝後仍不可用。請保留 runtime-download.log 與前後清單，改用已預裝該版本的 woow-ios17 自管 runner。") from None


def boot_simulator(output, simulator, report):
    """Keep the process exit code separate from bootstatus's terminal result."""
    log_path = output / "simulator-boot.log"
    report["boot_exit_code"] = None
    try:
        with log_path.open("wb") as log:
            completed = subprocess.run(["xcrun", "simctl", "bootstatus", simulator, "-b"],
                stdout=log, stderr=subprocess.STDOUT, timeout=900)
        report["boot_exit_code"] = completed.returncode
    except subprocess.TimeoutExpired:
        report["boot_timed_out"] = True
        raise ReleaseError("啟動指定 iOS 17 Simulator：工具執行逾時。") from None
    except OSError:
        raise ReleaseError("啟動指定 iOS 17 Simulator：無法執行工具或保存啟動紀錄。") from None
    finally:
        try:
            terminal = re.findall(r"Status=(\d+), isTerminal=YES[^\n]*\n[ \t]*([^\n]+)",
                                  log_path.read_text(errors="replace"))
            if terminal:
                status, description = terminal[-1]
                report["boot_terminal_status"] = int(status)
                # Observed in run 42758764668: terminal YES is not success.
                report["boot_data_migration_failed"] = description.strip() == "Data Migration Failed"
        except OSError:
            report["boot_terminal_log_unavailable"] = True
    if completed.returncode:
        raise ReleaseError("啟動指定 iOS 17 Simulator：失敗（退出碼 %d）。" % completed.returncode)
    if report.get("boot_data_migration_failed"):
        raise ReleaseError("iOS 17 Simulator 資料移轉失敗（Data Migration Failed）；未執行測試。")


def prelaunch_test_daemon(simulator, report):
    """Start this simulator's daemon once, before XCTest's control-session timer.

    The preserved 17.0.1 startup trace spent 106.6s in xpcproxy. Public
    launchctl kickstart (without -k) moves that initial launch out of the
    handshake. Process startup is NOT proof of an XCTest/AX handshake: only
    the subsequent, unchanged test invocation can establish that.
    No restart, private notify state, DTX request, or repeated launch is used.
    """
    diagnostic = {"budget_seconds": 120, "attempts": 0,
                  "status": "not_started", "handshake_verified": False}
    report["test_daemon_prelaunch"] = diagnostic
    started = time.monotonic()
    deadline = started + diagnostic["budget_seconds"]
    try:
        uuid.UUID(simulator)
        # Simulator's launchd uses the host user's domain (recorded as user/501
        # in the failing archive). Never address the host launchd directly.
        target = "user/%d/com.apple.testmanagerd" % os.getuid()
        base = ["xcrun", "simctl", "spawn", simulator, "launchctl"]
        environment = {key: os.environ[key] for key in
                       ("PATH", "DEVELOPER_DIR", "HOME", "TMPDIR", "TMP", "TEMP") if key in os.environ}
        environment.setdefault("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")

        def invoke(arguments):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(base, 120)
            result = subprocess.run(base + arguments, stdin=subprocess.DEVNULL,
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                    env=environment, timeout=remaining)
            if result.returncode != 0:
                diagnostic["status"] = "command_failed"
                raise ReleaseError("iOS 17 XCTest daemon 預啟動命令失敗；未執行測試。")
            # -p's documented result is a PID. Never copy raw command output
            # into reports, logs, or exceptions, including error output.
            if len(result.stdout) > 64:
                diagnostic["status"] = "invalid_command_output"
                raise ReleaseError("iOS 17 XCTest daemon 狀態格式不符；未執行測試。")
            return result.stdout.decode("utf-8", errors="replace")

        diagnostic["attempts"] = 1
        diagnostic["status"] = "starting"
        pid = invoke(["kickstart", "-p", target]).strip()
        if not re.fullmatch(r"[1-9][0-9]{0,9}", pid) or int(pid) > 2_147_483_647:
            diagnostic["status"] = "invalid_pid"
            raise ReleaseError("iOS 17 XCTest daemon 未回傳有效程序識別碼；未執行測試。")
        if time.monotonic() >= deadline:
            raise subprocess.TimeoutExpired(base, 120)
        diagnostic["status"] = "checking_process"
        # POSIX signal 0 checks existence/permission without sending a signal.
        # launchctl's own manual explicitly says print output is NOT an API;
        # do not infer readiness by parsing its state/initialized fields.
        try:
            os.kill(int(pid), 0)
        except OSError:
            diagnostic["status"] = "process_liveness_unconfirmed"
            raise ReleaseError("iOS 17 XCTest daemon 程序存活尚未確認；未執行測試。") from None
        if time.monotonic() >= deadline:
            raise subprocess.TimeoutExpired(base, 120)
        diagnostic["process_alive"] = True
        diagnostic["status"] = "process_started_handshake_unverified"
        # Internal receipt for the opt-in sampler only; never discover by name
        # or relaunch the service. PID is intentionally absent from the report.
        from ios17_bootstrap_watchdog import ServiceReceipt
        return ServiceReceipt(simulator, int(pid), time.time())
    except subprocess.TimeoutExpired:
        diagnostic["status"] = "budget_exhausted"
        raise ReleaseError("iOS 17 XCTest daemon 預啟動超過共用 120 秒預算；未重試或執行測試。") from None
    except (OSError, ValueError):
        diagnostic["status"] = "prelaunch_unavailable"
        raise ReleaseError("iOS 17 XCTest daemon 預啟動不可用；未執行測試。") from None
    finally:
        diagnostic["elapsed_seconds"] = round(time.monotonic() - started, 3)


def collect_boot_diagnostics(output, simulator):
    """Best-effort evidence from this fresh hosted device, never a personal Mac.

    Apple's Simulator guidance recommends diagnose immediately after failure.
    Query the installed tool's help rather than assuming Xcode-specific flags.
    Help and collection share one 90-second budget; no boot or diagnostic retry.
    """
    result = {"attempted": False, "budget_seconds": 90}
    if not (os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"
            and os.environ.get("RUNNER_OS") == "macOS"):
        return dict(result, status="skipped_not_ephemeral_hosted_macos")
    started = time.monotonic()
    stage = "help"
    try:
        uuid.UUID(simulator)
        help_log = output / "simctl-diagnose-help.log"
        with help_log.open("wb") as log:
            help_result = subprocess.run(["xcrun", "simctl", "help", "diagnose"],
                stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, timeout=10)
        result["help_exit_code"] = help_result.returncode
        if help_result.returncode:
            return dict(result, status="help_failed")
        help_text = help_log.read_text(errors="replace")
        flags = set(re.findall(r"(?<![\w-])(--[a-z][a-z-]*|-[a-zA-Z])(?=[\s=,<\[\])]|$)", help_text))
        # --udid scopes devices, -l suppresses the privacy prompt, and -q
        # prevents opening Finder. Never fall back to an unscoped diagnose.
        if not {"--udid", "--output", "-l", "-q"}.issubset(flags):
            return dict(result, status="skipped_required_flags_unavailable")
        remaining = 90 - (time.monotonic() - started)
        if remaining <= 0:
            return dict(result, status="skipped_budget_exhausted")
        destination = output / "boot-diagnostics"
        destination.mkdir()
        stage = "collection"
        with (output / "simctl-diagnose.log").open("wb") as log:
            result.update(attempted=True, timeout_seconds=remaining)
            completed = subprocess.run(["xcrun", "simctl", "diagnose", "-l", "-q",
                "--udid=" + simulator, "--output=" + str(destination.resolve())],
                stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, timeout=remaining)
        result.update(status="completed" if completed.returncode == 0 else "failed",
                      exit_code=completed.returncode)
    except subprocess.TimeoutExpired:
        result.update(status=stage + "_timed_out")
    except (OSError, ValueError, subprocess.SubprocessError):
        # Keep fixed status fields; raw diagnostic details stay in the hosted
        # artifact and must not be echoed into a primary boot exception.
        result.update(status=stage + "_unavailable")
    return result


def observed_ui_events(log_path, expected):
    """Diagnostic only: log events never substitute for a successful xcresult.

    Keep fixed counts and source-inventoried method names, not assertion text,
    launch arguments, or arbitrary names printed by the process under test.
    """
    limit = 16 * 1024 * 1024
    if log_path.stat().st_size > limit:
        return {"status": "log_size_limit", "acceptance_evidence": False}
    methods = {name: {"starts": 0, "passed": 0, "failed": 0, "skipped": 0} for name in expected}
    unexpected = 0
    pattern = re.compile(r"^Test Case '-\[WoowAssistantUITests\.(\w+) (test\w+)\]' (started|passed|failed|skipped)(?:\.| \()")
    with log_path.open("rb") as log:
        text = log.read(limit + 1)
    if len(text) > limit:
        return {"status": "log_size_limit", "acceptance_evidence": False}
    for line in text.decode("utf-8", errors="replace").splitlines():
        match = pattern.match(line)
        if not match:
            continue
        name, method, outcome = match.groups()
        key = "WoowAssistantUITests/" + name + "/" + method
        if key not in methods:
            unexpected += 1
            continue
        methods[key]["starts" if outcome == "started" else outcome] += 1
    totals = {key: sum(value[key] for value in methods.values())
              for key in ("starts", "passed", "failed", "skipped")}
    complete = bool(methods) and not unexpected and all(
        row["starts"] == 1 and sum(row[k] for k in ("passed", "failed", "skipped")) == 1
        for row in methods.values())
    return {"status": "observed", "acceptance_evidence": False, "expected_methods": len(methods),
            "counts": totals, "unexpected_events": unexpected,
            "all_expected_completed_once": complete, "methods": methods}


def build_before_simulator(common, output, report):
    """One build, before creating the owned simulator; debit the existing budget."""
    budget = report["build_test_timeout_seconds"]
    began = time.monotonic()
    try:
        with (output / "build-for-testing.log").open("wb") as log:
            result = subprocess.run(common + ["-destination", "generic/platform=iOS Simulator",
                "build-for-testing", "ARCHS=" + report["host_architecture"],
                "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_ALLOWED=YES"],
                stdout=log, stderr=subprocess.STDOUT, timeout=budget)
        report["prebuild_exit_code"] = result.returncode
        if result.returncode:
            raise ReleaseError("iOS 17 預編譯失敗；尚未建立 Simulator，請查看 build-for-testing.log。")
    except subprocess.TimeoutExpired:
        report["prebuild_timed_out"] = True
        raise ReleaseError("iOS 17 預編譯耗盡原有編譯／測試額度；尚未建立 Simulator。") from None
    finally:
        elapsed = max(0, time.monotonic() - began)
        report["prebuild_elapsed_seconds"] = round(elapsed, 3)
        report["remaining_test_timeout_seconds"] = max(0, budget - elapsed)
    if report["remaining_test_timeout_seconds"] <= 0:
        raise ReleaseError("iOS 17 預編譯耗盡原有編譯／測試額度；尚未建立 Simulator。")
    products = output / "DerivedData" / "Build" / "Products"
    manifests = list(products.glob("*.xctestrun"))
    if len(manifests) != 1 or manifests[0].is_symlink():
        raise ReleaseError("預編譯未產生唯一的本次 xctestrun；尚未建立 Simulator。")
    manifest = manifests[0]
    if not 0 < manifest.stat().st_size <= 1024 * 1024:
        raise ReleaseError("預編譯 xctestrun 大小不符；尚未建立 Simulator。")
    data = manifest.read_bytes()
    try:
        value = plistlib.loads(data)
        if not isinstance(value, dict) or not value:
            raise ValueError()
    except (ValueError, plistlib.InvalidFileException):
        raise ReleaseError("預編譯 xctestrun 格式不符；尚未建立 Simulator。") from None
    report["prebuilt_xctestrun"] = {"path": str(manifest.relative_to(output)),
                                    "sha256": hashlib.sha256(data).hexdigest()}
    return manifest


def execute(output, requested, download, test_scope="all", expected_host_arch=None, prelaunch_daemon=False,
            *, sample_bootstrap=False, bounded_test_diagnostics=False, build_before_boot=False):
    if version(requested)[0] != 17:
        raise ReleaseError("只接受 iOS 17.x。")
    if test_scope not in TEST_SCOPES:
        raise ReleaseError("未知的 iOS 17 測試範圍。")
    if expected_host_arch not in (None, "arm64", "x86_64"):
        raise ReleaseError("未知的主機架構。")
    if build_before_boot and (test_scope not in ({"startup-smoke", "pdf-assembly", "pdf-assembly-copy", "pdf-assembly-multi", "pdf-pair-coordinated", "documents-read", "documents-output", "documents-chat"} | UI_SHARDS.keys())
                              or not sample_bootstrap or not prelaunch_daemon):
        raise ReleaseError("預編譯啟動比較只允許明確預啟動及取樣的 hosted 非 Live UI 分片或既有 smoke／PDF 文件分組；未執行測試。")
    if bounded_test_diagnostics and not sample_bootstrap:
        raise ReleaseError("限制失敗後系統診斷只允許已啟用 bootstrap 取樣的 hosted 非 Live fixture 比較。")
    if sample_bootstrap:
        from ios17_bootstrap_watchdog import validate_gate
        try:
            validate_gate(os.environ, output, prelaunch_daemon, TEST_SCOPES[test_scope])
        except ValueError:
            raise ReleaseError("Bootstrap 取樣只允許明確啟用預啟動的 GitHub hosted 非 Live UI fixture；未執行測試。") from None
    output.mkdir(parents=True, exist_ok=False)
    report = {"requested_runtime": requested, "runtime_tested": False,
              "deployment_target": "17.0", "physical_devices_used": False,
              "host_architecture": platform.machine(), "host_macos": platform.mac_ver()[0],
              "expected_host_architecture": expected_host_arch,
              "experimental_prelaunch_test_daemon": prelaunch_daemon,
              "experimental_sample_bootstrap": sample_bootstrap,
              "experimental_bounded_test_diagnostics": bounded_test_diagnostics,
              "experimental_build_before_boot": build_before_boot,
              "phase_history": [], "test_scope": test_scope,
              "selected_tests_succeeded": False,
              "full_acceptance_succeeded": False,
              "coverage_kind": ("ui-shard" if test_scope in UI_SHARDS else
                                "full-scheme" if test_scope == "all" else
                                "native-core" if test_scope == "core" else "focused"),
              "source_revision": (os.environ.get("GITHUB_SHA") if re.fullmatch(
                  r"[0-9a-f]{40}", os.environ.get("GITHUB_SHA", "")) else None)}
    started = time.monotonic()

    def save_report():
        temporary = output / "report.json.tmp"
        temporary.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        temporary.replace(output / "report.json")

    def checkpoint(phase):
        # Persist before starting a slow operation, so a runner termination does
        # not erase the last known phase. Log only fixed phase/OS metadata.
        report["phase"] = phase
        event = {"phase": phase, "requested_runtime": requested,
                 "at": datetime.now(timezone.utc).isoformat(),
                 "elapsed_seconds": round(time.monotonic() - started, 1)}
        report["phase_history"].append(event)
        save_report()
        print(json.dumps(event), flush=True)

    simulator = None
    try:
        checkpoint("preflight")
        if expected_host_arch and report["host_architecture"] != expected_host_arch:
            raise ReleaseError("實際主機架構與指定比較條件不同；未執行測試。")
        root = Path(__file__).resolve().parents[1]
        catalog = ui_inventory(root)
        (output / "ui-test-inventory.json").write_text(json.dumps(catalog, indent=2) + "\n")
        report["ui_inventory_sha256"] = catalog["inventory_sha256"]
        report["expected_ui_tests"] = selected_ui_tests(catalog, test_scope)
        report["live_ui_selected"] = test_scope == "all"
        report["live_ui_not_selected"] = [] if test_scope == "all" else catalog["live_tests_excluded"]
        report["xcode"] = run(["xcodebuild", "-version"], "需要完整 Xcode").decode().strip()
        checkpoint("checking_runtime")
        runtime = ensure_runtime(output, requested, download, checkpoint)
        report["selected_runtime"] = runtime
        checkpoint("generating_project")
        project = generate_project(root, output)
        common = ["xcodebuild", "-project", str(project), "-scheme", "WoowAssistant",
                  "-sdk", "iphonesimulator", "-derivedDataPath", str(output / "DerivedData")]
        checkpoint("checking_build_settings")
        settings = json.loads(run(common + ["-destination", "generic/platform=iOS Simulator",
                                  "-showBuildSettings", "-json"], "檢查最低系統設定"))
        verify_settings(settings)
        report["maximum_case_seconds"] = 420 if test_scope in ("all", "workspace", "ui-workspace") else 300
        report["build_test_timeout_seconds"] = 1800 if test_scope in UI_SHARDS or test_scope in DOCUMENT_SCOPES else 4800
        manifest = None
        if build_before_boot:
            checkpoint("building_before_boot")
            manifest = build_before_simulator(common, output, report)
            checkpoint("prebuilt_tests_ready")
        checkpoint("creating_simulator")
        simulator = run(["xcrun", "simctl", "create", "Woow-iOS17-" + uuid.uuid4().hex,
                         "com.apple.CoreSimulator.SimDeviceType.iPhone-15", runtime["identifier"]],
                        "建立此次驗證專用 Simulator").decode().strip()
        # Validate before using the identifier for any mutation.
        uuid.UUID(simulator)
        checkpoint("booting")
        # Newly installed runtimes can spend several minutes preparing their
        # shared caches. Keep bounded boot output rather than hiding the cause.
        try:
            boot_simulator(output, simulator, report)
            report["boot_succeeded"] = True
        except ReleaseError as error:
            report["boot_succeeded"] = False
            report["boot_error"] = str(error)
            try:
                # Persist the primary failure before optional work. Collect
                # before even the inventory query, which can itself hang.
                save_report()
                report["boot_diagnostics"] = collect_boot_diagnostics(output, simulator)
            except Exception:
                # Optional evidence (including filesystem/parser failures)
                # must never replace the original boot error or skip cleanup.
                report["boot_diagnostics"] = {"status": "unexpected_diagnostic_error"}
            raise
        finally:
            # Inventory is diagnostic only. In run 42758809838 bootstatus
            # finished successfully, then this extra query timed out. In
            # 42758764668 the same query masked the real data-migration failure.
            save_report()
            try:
                devices = json.loads(run(["xcrun", "simctl", "list", "devices", "--json"], "取得測試裝置狀態", timeout=30))
                own = [item for group in devices.get("devices", {}).values() for item in group if item.get("udid") == simulator]
                report["simulator_state"] = [{key: item.get(key) for key in ("state", "isAvailable", "availabilityError")} for item in own]
            except (ReleaseError, ValueError, TypeError, AttributeError):
                report["simulator_state_unavailable"] = True
        daemon_receipt = None
        if prelaunch_daemon:
            checkpoint("prelaunching_test_daemon")
            try:
                daemon_receipt = prelaunch_test_daemon(simulator, report)
            finally:
                save_report()
        # New class shards aim for 10–20 minutes of testing, with a bounded
        # 30-minute build+test budget. Existing repair scopes keep their bounds.
        checkpoint("testing")
        with (output / "tests.log").open("wb") as log:
            watcher = None
            if sample_bootstrap:
                from ios17_bootstrap_watchdog import OwnedProcesses, PublicProcessIdentity, Watchdog, runtime_root
                try:
                    owned = OwnedProcesses(simulator, daemon_receipt, runtime_root(output, runtime),
                                           PublicProcessIdentity(), os.getuid())
                    watcher = Watchdog(output, owned)
                    report["bootstrap_sampling_status"] = "observing"
                except (OSError, ValueError, KeyError, TypeError):
                    # Optional diagnostics must not replace XCTest or its verdict.
                    report["bootstrap_sampling_status"] = "identity_unavailable"
                save_report()
            # If owned sampling could not be initialized, retain Xcode's
            # default diagnostics instead of silently losing both sources.
            suppress_verbose_diagnostics = bounded_test_diagnostics and watcher is not None
            report["verbose_failure_diagnostics"] = (
                "disabled_with_bounded_sampling" if suppress_verbose_diagnostics else "xcode_default")
            try:
                test_common = ["xcodebuild", "-xctestrun", str(manifest)] if manifest else common
                test_action = "test-without-building" if manifest else "test"
                test_budget = report.get("remaining_test_timeout_seconds", report["build_test_timeout_seconds"])
                arguments = (test_common + ["-destination", "platform=iOS Simulator,id=" + simulator,
                    "-resultBundlePath", str(output / "Tests.xcresult"), "-parallel-testing-enabled", "NO",
                    "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "240",
                    "-maximum-test-execution-time-allowance", str(report["maximum_case_seconds"])] +
                    (["-collect-test-diagnostics", "never"] if suppress_verbose_diagnostics else []) +
                    ["-only-testing:" + target for target in TEST_SCOPES[test_scope]] +
                    [test_action, "CODE_SIGN_IDENTITY=-",
                    "CODE_SIGNING_ALLOWED=YES"])
                if watcher is not None:
                    from ios17_bootstrap_watchdog import run_observed
                    result = run_observed(arguments, log, test_budget, watcher)
                    report["bootstrap_sampling_status"] = "stopped"
                else:
                    result = subprocess.run(arguments, stdout=log, stderr=subprocess.STDOUT,
                                            timeout=test_budget)
            except subprocess.TimeoutExpired:
                report["test_timed_out"] = True
                raise ReleaseError("iOS 17 編譯／所選測試超過 %d 分鐘；保留已執行結果，不視為通過。" %
                                   (report["build_test_timeout_seconds"] // 60)) from None
            finally:
                if watcher is not None:
                    report["bootstrap_sampling_status"] = watcher.report.get("status", "unavailable")
                # Preserve real method progress even when xcodebuild is killed
                # while finalizing diagnostics and cannot finish its bundle.
                # These observations do not alter exit/summary acceptance.
                if report["expected_ui_tests"]:
                    try:
                        log.flush()
                        events = observed_ui_events(output / "tests.log", report["expected_ui_tests"])
                        report["observed_ui_events"] = events
                        if report.get("test_timed_out"):
                            report["timeout_phase"] = (
                                "after_selected_ui_methods" if events.get("all_expected_completed_once") else
                                "during_selected_ui_methods" if events.get("counts", {}).get("starts", 0) else
                                "before_selected_ui_methods" if events.get("status") == "observed" else "unknown")
                    except (OSError, ValueError):
                        report["observed_ui_events"] = {"status": "unavailable", "acceptance_evidence": False}
        report["test_exit_code"] = result.returncode
        if result.returncode:
            raise ReleaseError("iOS 17 建置／XCTest 失敗；請查看 tests.log 與 Tests.xcresult。")
        checkpoint("verifying_test_completion")
        summary_bytes = run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path",
                             str(output / "Tests.xcresult")], "讀取實際 XCTest 摘要", timeout=120)
        (output / "test-summary.json").write_bytes(summary_bytes)
        summary = json.loads(summary_bytes)
        if not isinstance(summary, dict):
            raise ReleaseError("XCTest 摘要格式不符，不能宣稱測試完成。")
        report["test_completion"] = test_completion(summary, output / "tests.log",
            report["expected_ui_tests"], bool(TEST_SCOPES[test_scope]) and
            all(t.startswith("WoowAssistantUITests/") for t in TEST_SCOPES[test_scope]))
        if not report["test_completion"]["verified"]:
            raise ReleaseError("XCTest 摘要或 UI 完成清單不符：有略過、遺漏、重複或未通過案例；不視為驗收通過。")
        report["selected_tests_succeeded"] = True
        # A full scheme must include Live cases with zero skips to set these.
        # Passing a shard never certifies other shards, core, or Live services.
        report["runtime_tested"] = test_scope == "all"
        report["full_acceptance_succeeded"] = test_scope == "all"
        checkpoint("passed")
    except RuntimeInventoryError as error:
        # The original exception still reaches main() and exits 1. Persist only
        # the fixed failure receipt, including the bounded inventory attempts.
        report["failure"] = error.diagnostic
        raise
    finally:
        save_report()
        if simulator:
            # Only the simulator created by this invocation is removed.
            # Still attempt delete after a shutdown error, and never replace
            # the original boot/test failure with a secondary cleanup failure.
            failed = sys.exc_info()[0] is not None
            try:
                subprocess.run(["xcrun", "simctl", "shutdown", simulator], capture_output=True, timeout=60)
            except (OSError, subprocess.TimeoutExpired):
                report["simulator_shutdown_incomplete"] = True
            try:
                run(["xcrun", "simctl", "delete", simulator], "刪除此驗證專用 Simulator")
                report["simulator_deleted"] = True
            except ReleaseError:
                report["simulator_deleted"] = False
                if not failed:
                    raise
            finally:
                save_report()
    print(json.dumps(report, ensure_ascii=False, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--os", default="17.0.1", help="Exact OS version, not device model number")
    parser.add_argument("--download", action="store_true")
    parser.add_argument("--test-scope", choices=TEST_SCOPES, default="all")
    parser.add_argument("--expected-host-arch", choices=("arm64", "x86_64"))
    parser.add_argument("--prelaunch-test-daemon", action="store_true",
                        help="Experimental one-shot daemon prelaunch; not proof of XCTest readiness (default off)")
    parser.add_argument("--sample-test-bootstrap", action="store_true",
                        help="Experimental bounded hosted fixture process stacks; requires prelaunch (default off)")
    parser.add_argument("--bounded-test-diagnostics", action="store_true",
                        help="Experimental suppression of verbose failure system logs; requires hosted fixture sampling (default off)")
    parser.add_argument("--build-before-boot", action="store_true",
                        help="Experimental prebuild; sampled hosted non-Live ui-* shards or existing smoke/PDF document groups only (default off)")
    parser.add_argument("--check-ui-inventory", action="store_true",
                        help="Validate and print the UI class partition without invoking Xcode")
    parser.add_argument("--output", type=Path, default=Path("build/ios17"))
    args = parser.parse_args()
    try:
        if args.check_ui_inventory:
            print(json.dumps(ui_inventory(Path(__file__).resolve().parents[1]), indent=2))
            return 0
        execute(args.output.resolve(), args.os, args.download, args.test_scope, args.expected_host_arch,
                args.prelaunch_test_daemon, sample_bootstrap=args.sample_test_bootstrap,
                bounded_test_diagnostics=args.bounded_test_diagnostics, build_before_boot=args.build_before_boot)
    except (ReleaseError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(str(error) if isinstance(error, ReleaseError) else "iOS 17 驗證未完成；請檢查輸出證據。", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
