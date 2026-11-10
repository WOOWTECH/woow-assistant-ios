#!/usr/bin/env python3
"""Prepare one disposable, exact-version Simulator for private live workflows.

Run before any secret-bearing steps. Only fixed metadata and two validated
GitHub environment values are published; no live artifact is uploaded. iOS
17.0.1 uses the existing bounded Apple installer/boot path, while the default
18.5 must already be installed with Xcode 16.4. Neither path selects a fallback.
The always-run --cleanup command only deletes the UUID created in this state.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import sys
import uuid

import release_ios17 as ios17
from release_ios import ReleaseError, run, version

RUNTIMES = {
    "17.0.1": "com.apple.CoreSimulator.SimDeviceType.iPhone-15",
    "18.5": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro-Max",
}
RUNTIME_IDS = {
    "17.0.1": {"com.apple.CoreSimulator.SimRuntime.iOS-17-0", "com.apple.CoreSimulator.SimRuntime.iOS-17-0-1"},
    "18.5": {"com.apple.CoreSimulator.SimRuntime.iOS-18-5"},
}
OWNER = "woow-private-live-simulator-v1"
STATE = "simulator.json"


def save(output, report):
    temporary = output / (STATE + ".tmp")
    temporary.write_text(json.dumps(report, sort_keys=True, indent=2) + "\n")
    temporary.replace(output / STATE)


def select_runtime(payload, requested):
    if requested not in RUNTIMES:
        raise ReleaseError("Live Simulator 只接受精確的 17.0.1 或 18.5。")
    if requested == "17.0.1":
        return ios17.select_runtime(payload, requested)
    matches = [item for item in payload.get("runtimes", [])
               if item.get("identifier") == "com.apple.CoreSimulator.SimRuntime.iOS-18-5"
               and item.get("isAvailable") is True
               and version(item.get("version", "0.0")) == version(requested)]
    if len(matches) != 1:
        raise ReleaseError("找不到唯一可用的 iOS 18.5 runtime；不會改用其他版本。")
    return {key: matches[0].get(key) for key in ("identifier", "version", "buildversion")}


def cleanup(output):
    path = output / STATE
    if not path.exists():
        return {"cleanup": "no_created_simulator"}
    if path.is_symlink() or path.stat().st_size > 8192:
        raise ReleaseError("Live Simulator 清理紀錄無效；未刪除任何裝置。")
    report = json.loads(path.read_text())
    if report.get("owner") != OWNER or report.get("requested_runtime") not in RUNTIMES:
        raise ReleaseError("Live Simulator 清理紀錄不屬於此工具；未刪除任何裝置。")
    simulator = report.get("simulator_id")
    if simulator is None:
        return {"cleanup": "no_created_simulator"}
    try:
        valid_id = str(uuid.UUID(simulator)).upper() == simulator
    except (ValueError, TypeError, AttributeError):
        valid_id = False
    if not valid_id or not re.fullmatch(r"Woow-Live-[0-9a-f]{32}", report.get("device_name", "")):
        raise ReleaseError("Live Simulator 裝置紀錄無效；未刪除任何裝置。")
    if report.get("simulator_deleted") is True:
        return {"cleanup": "already_deleted", "simulator_id": simulator}
    # No all-device shutdown/erase/delete, and no retry of a failed cleanup.
    if report.get("cleanup_attempted"):
        raise ReleaseError("此次 Live Simulator 清理已失敗；未重試或刪除其他裝置。")
    report["cleanup_attempted"] = True
    save(output, report)
    try:
        run(["xcrun", "simctl", "shutdown", simulator], "停止此次 Live Simulator", timeout=60)
        report["shutdown_succeeded"] = True
    except ReleaseError:
        # A failed boot can leave the device already shut down. Still delete it.
        report["shutdown_succeeded"] = False
    try:
        run(["xcrun", "simctl", "delete", simulator], "刪除此次 Live Simulator", timeout=60)
        report["simulator_deleted"] = True
    except ReleaseError:
        report["simulator_deleted"] = False
        raise
    finally:
        save(output, report)
    return {"cleanup": "deleted", "simulator_id": simulator}


def prepare(output, requested, github_env):
    if requested not in RUNTIMES:
        raise ReleaseError("Live Simulator 只接受精確的 17.0.1 或 18.5。")
    # Refuse to overwrite a previous invocation's ownership record.
    output.mkdir(parents=True, exist_ok=False)
    report = {"owner": OWNER, "requested_runtime": requested,
              "host_architecture": platform.machine(), "phase": "preflight",
              "boot_succeeded": False, "physical_devices_used": False}

    def checkpoint(phase):
        report["phase"] = phase
        save(output, report)
        print(json.dumps({"phase": phase, "requested_runtime": requested}), flush=True)

    checkpoint("preflight")
    try:
        if report["host_architecture"] != "arm64":
            raise ReleaseError("Private Live 驗證要求 ARM 主機；未建立 Simulator。")
        xcode = run(["xcodebuild", "-version"], "檢查 Xcode 16.4").decode().strip()
        if xcode != "Xcode 16.4\nBuild version 16F6":
            raise ReleaseError("Private Live 驗證要求固定 Xcode 16.4（16F6）。")
        report["xcode"] = "16.4 (16F6)"
        checkpoint("checking_runtime")
        if requested == "17.0.1":
            runtime = ios17.ensure_runtime(output, requested, True, checkpoint)
        else:
            runtime = select_runtime(ios17.inventory(output, "runtimes-before.json"), requested)
        # Validate even installer results before constructing any environment line.
        identifier = runtime.get("identifier", "")
        if (version(runtime.get("version", "0.0")) != version(requested)
                or identifier not in RUNTIME_IDS[requested]):
            raise ReleaseError("已選 runtime 的版本或識別資料不符；未建立 Simulator。")
        report["selected_runtime"] = runtime
        report["device_name"] = "Woow-Live-" + uuid.uuid4().hex
        checkpoint("creating_simulator")
        created = run(["xcrun", "simctl", "create", report["device_name"], RUNTIMES[requested], identifier],
                      "建立此次 Private Live Simulator").decode().strip()
        try:
            simulator = str(uuid.UUID(created)).upper()
        except ValueError:
            raise ReleaseError("新建 Simulator 未回傳有效 UUID；未輸出環境設定。") from None
        report["simulator_id"] = simulator
        checkpoint("booting")  # Persist ownership before the bounded boot command.
        try:
            ios17.boot_simulator(output, simulator, report)
        except ReleaseError as error:
            # The shared implementation's original messages name iOS 17.
            raise ReleaseError(str(error).replace("iOS 17", "iOS " + requested)) from None
        report["boot_succeeded"] = True
        # A new device is intentionally retained until the workflows' always step.
        with github_env.open("a") as env:
            env.write("WOOW_LIVE_SIMULATOR=" + simulator + "\n")
            env.write("WOOW_LIVE_RUNTIME=" + identifier.rsplit(".", 1)[1] + "\n")
        checkpoint("ready")
        return report
    except Exception:
        save(output, report)
        try:
            cleanup(output)
        except Exception:
            # Keep the original setup/boot failure, not a secondary delete error.
            pass
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--os", choices=tuple(RUNTIMES), default="18.5")
    parser.add_argument("--output", type=Path, default=Path("build/live-simulator"))
    parser.add_argument("--github-env", type=Path)
    parser.add_argument("--cleanup", action="store_true")
    args = parser.parse_args()
    try:
        if args.cleanup:
            result = cleanup(args.output)
        else:
            target = args.github_env or (Path(os.environ["GITHUB_ENV"]) if os.environ.get("GITHUB_ENV") else None)
            if target is None:
                raise ReleaseError("缺少 GitHub 環境輸出檔；未建立 Simulator。")
            result = prepare(args.output, args.os, target)
        print(json.dumps(result, sort_keys=True))
    except ReleaseError as error:
        print(str(error), file=sys.stderr)
        return 1
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        print("Private Live Simulator 設定／紀錄格式錯誤；未輸出工具內容。", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
