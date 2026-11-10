#!/usr/bin/env python3
"""Run the existing XCTest scheme on an exact iOS 17 simulator runtime.

No fallback to iOS 18/26. --download uses Apple's supported installer only.
A disposable simulator is created and deleted; physical devices are untouched.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

from release_ios import ReleaseError, generate_project, run, version, verify_settings


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


def ensure_runtime(output, requested, download):
    payload = inventory(output, "runtimes-before.json")
    try:
        return select_runtime(payload, requested)
    except ReleaseError:
        if not download:
            raise ReleaseError("缺少指定 runtime。請預裝後重試，或在 hosted runner 使用 --download。") from None
    # Keep the actual installer failure as evidence; these arguments contain no secrets.
    with (output / "runtime-download.log").open("wb") as log:
        try:
            completed = subprocess.run(["xcodebuild", "-downloadPlatform", "iOS", "-buildVersion", requested],
                                       stdout=log, stderr=subprocess.STDOUT, timeout=1200)
            (output / "runtime-download-status.json").write_text(json.dumps({"exit_code": completed.returncode}) + "\n")
        except subprocess.TimeoutExpired:
            (output / "runtime-download-status.json").write_text('{"timed_out": true}\n')
    payload = inventory(output, "runtimes-after.json")
    try:
        return select_runtime(payload, requested)
    except ReleaseError:
        raise ReleaseError("指定 iOS 17 runtime 下載／安裝後仍不可用。請保留 runtime-download.log 與前後清單，改用已預裝該版本的 woow-ios17 自管 runner。") from None


def execute(output, requested, download):
    if version(requested)[0] != 17:
        raise ReleaseError("只接受 iOS 17.x。")
    output.mkdir(parents=True, exist_ok=False)
    report = {"requested_runtime": requested, "runtime_tested": False,
              "deployment_target": "17.0", "physical_devices_used": False}
    simulator = None
    try:
        report["xcode"] = run(["xcodebuild", "-version"], "需要完整 Xcode").decode().strip()
        runtime = ensure_runtime(output, requested, download)
        report["selected_runtime"] = runtime
        root = Path(__file__).resolve().parents[1]
        project = generate_project(root, output)
        common = ["xcodebuild", "-project", str(project), "-scheme", "WoowAssistant",
                  "-sdk", "iphonesimulator", "-derivedDataPath", str(output / "DerivedData")]
        settings = json.loads(run(common + ["-destination", "generic/platform=iOS Simulator",
                                  "-showBuildSettings", "-json"], "檢查最低系統設定"))
        verify_settings(settings)
        simulator = run(["xcrun", "simctl", "create", "Woow-iOS17-" + uuid.uuid4().hex,
                         "com.apple.CoreSimulator.SimDeviceType.iPhone-15", runtime["identifier"]],
                        "建立此次驗證專用 Simulator").decode().strip()
        # Validate before using the identifier for any mutation.
        uuid.UUID(simulator)
        run(["xcrun", "simctl", "bootstatus", simulator, "-b"], "啟動指定 iOS 17 Simulator", timeout=300)
        with (output / "tests.log").open("wb") as log:
            result = subprocess.run(common + ["-destination", "platform=iOS Simulator,id=" + simulator,
                "-resultBundlePath", str(output / "Tests.xcresult"), "-parallel-testing-enabled", "NO",
                "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "240",
                "-maximum-test-execution-time-allowance", "300", "test", "CODE_SIGN_IDENTITY=-",
                "CODE_SIGNING_ALLOWED=YES"], stdout=log, stderr=subprocess.STDOUT, timeout=3300)
        if result.returncode:
            raise ReleaseError("iOS 17 建置／XCTest 失敗；請查看 tests.log 與 Tests.xcresult。")
        report["runtime_tested"] = True
    finally:
        (output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        if simulator:
            # Only the simulator created by this invocation is removed.
            subprocess.run(["xcrun", "simctl", "shutdown", simulator], capture_output=True, timeout=60)
            run(["xcrun", "simctl", "delete", simulator], "刪除此驗證專用 Simulator")
    print(json.dumps(report, ensure_ascii=False, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--os", default="17.0.1", help="Exact OS version, not device model number")
    parser.add_argument("--download", action="store_true")
    parser.add_argument("--output", type=Path, default=Path("build/ios17"))
    args = parser.parse_args()
    try:
        execute(args.output.resolve(), args.os, args.download)
    except (ReleaseError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(str(error) if isinstance(error, ReleaseError) else "iOS 17 驗證未完成；請檢查輸出證據。", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
