#!/usr/bin/env python3
"""Run the existing XCTest scheme on an exact iOS 17 simulator runtime.

No fallback to iOS 18/26. --download uses Apple's supported installer only.
A disposable simulator is created and deleted; physical devices are untouched.
"""
import argparse
from datetime import datetime, timezone
import json
import os
import platform
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid

from release_ios import ReleaseError, generate_project, run, version, verify_settings

TEST_SCOPES = {
    "all": [],
    "core": ["AssistantDomainTests", "AssistantModelsTests", "AssistantMCPTests", "AssistantMemoryTests", "AssistantSkillsTests", "AssistantPersistenceTests", "AssistantBrowserIntegrationTests"],
    "workspace": ["AssistantDomainTests/BrowserLibraryTests", "AssistantDomainTests/BrowserPolicyTests", "AssistantDomainTests/BrowserNavigationIntentTests", "AssistantBrowserIntegrationTests", "WoowAssistantUITests/BrowserWorkspaceUITests", "WoowAssistantUITests/BrowserLoginUITests"],
    "files": ["AssistantSkillsTests", "AssistantDomainTests/BrowserDownloadTests", "AssistantDomainTests/BrowserNavigationIntentTests", "AssistantBrowserIntegrationTests", "WoowAssistantUITests/BrowserUploadUITests", "WoowAssistantUITests/SkillExecutionUITests"],
    "parity": ["AssistantMCPTests", "AssistantSkillsTests", "AssistantDomainTests", "AssistantBrowserIntegrationTests", "WoowAssistantUITests/MCPConversationUITests", "WoowAssistantUITests/BrowserInteractionUITests", "WoowAssistantUITests/BrowserLearningUITests", "WoowAssistantUITests/SkillCatalogUITests", "WoowAssistantUITests/MemoryUITests", "WoowAssistantUITests/MemoryRaceUITests"],
    "startup": ["WoowAssistantUITests/WoowAssistantUITests"],
}


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
    payload = json.loads(run(["xcrun", "simctl", "list", "runtimes", "--json"], "取得 Simulator runtime 清單"))
    # Only OS metadata, not personal simulator/device names or UDIDs.
    metadata = {"runtimes": [{key: r.get(key) for key in
                ("identifier", "version", "buildversion", "isAvailable", "availabilityError")}
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


def execute(output, requested, download, test_scope="all"):
    if version(requested)[0] != 17:
        raise ReleaseError("只接受 iOS 17.x。")
    if test_scope not in TEST_SCOPES:
        raise ReleaseError("未知的 iOS 17 測試範圍。")
    output.mkdir(parents=True, exist_ok=False)
    report = {"requested_runtime": requested, "runtime_tested": False,
              "deployment_target": "17.0", "physical_devices_used": False,
              "host_architecture": platform.machine(), "host_macos": platform.mac_ver()[0],
              "phase_history": [], "test_scope": test_scope,
              "selected_tests_succeeded": False}
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
        report["xcode"] = run(["xcodebuild", "-version"], "需要完整 Xcode").decode().strip()
        checkpoint("checking_runtime")
        runtime = ensure_runtime(output, requested, download, checkpoint)
        report["selected_runtime"] = runtime
        root = Path(__file__).resolve().parents[1]
        checkpoint("generating_project")
        project = generate_project(root, output)
        common = ["xcodebuild", "-project", str(project), "-scheme", "WoowAssistant",
                  "-sdk", "iphonesimulator", "-derivedDataPath", str(output / "DerivedData")]
        checkpoint("checking_build_settings")
        settings = json.loads(run(common + ["-destination", "generic/platform=iOS Simulator",
                                  "-showBuildSettings", "-json"], "檢查最低系統設定"))
        verify_settings(settings)
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
        checkpoint("testing")
        with (output / "tests.log").open("wb") as log:
            try:
                result = subprocess.run(common + ["-destination", "platform=iOS Simulator,id=" + simulator,
                    "-resultBundlePath", str(output / "Tests.xcresult"), "-parallel-testing-enabled", "NO",
                    "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "240",
                    "-maximum-test-execution-time-allowance", "300"] +
                    ["-only-testing:" + target for target in TEST_SCOPES[test_scope]] +
                    ["test", "CODE_SIGN_IDENTITY=-",
                    "CODE_SIGNING_ALLOWED=YES"], stdout=log, stderr=subprocess.STDOUT, timeout=4800)
            except subprocess.TimeoutExpired:
                report["test_timed_out"] = True
                raise ReleaseError("iOS 17 編譯／完整測試超過 80 分鐘；保留已執行結果，不視為通過。") from None
        report["test_exit_code"] = result.returncode
        if result.returncode:
            raise ReleaseError("iOS 17 建置／XCTest 失敗；請查看 tests.log 與 Tests.xcresult。")
        report["selected_tests_succeeded"] = True
        # Retain the original full-scheme meaning. A focused repair run can
        # pass its selected cases without certifying the complete acceptance set.
        report["runtime_tested"] = test_scope == "all"
        checkpoint("passed")
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
    parser.add_argument("--output", type=Path, default=Path("build/ios17"))
    args = parser.parse_args()
    try:
        execute(args.output.resolve(), args.os, args.download, args.test_scope)
    except (ReleaseError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(str(error) if isinstance(error, ReleaseError) else "iOS 17 驗證未完成；請檢查輸出證據。", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
