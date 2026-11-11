#!/usr/bin/env python3
"""Snapshot and execute notification state + actual ChatSession/UN content checks.

No UNUserNotificationCenter.current(), permission prompt, network, personal
defaults or Keychain is accessed. Native request objects are constructed only.
iOS parsing is syntax evidence, never native build/UI/delivery acceptance.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time

MODULES = [
    ("AssistantContracts", []), ("AssistantDomain", ["AssistantContracts"]),
    ("AssistantModels", []), ("AssistantMemory", ["AssistantModels"]),
    ("AssistantPersistence", []), ("AssistantMCP", ["AssistantModels"]),
    ("AssistantSkills", ["AssistantModels"]), ("AssistantBrowser", ["AssistantModels", "AssistantSkills"]),
]
LANGUAGE_NOTIFICATION_SOURCES = ["AppLanguage", "AppLanguageStore", "AppLanguagePreferences", "AppText", "AppLocalizer", "AppMCPText", "AppNotificationText"]
APPS = LANGUAGE_NOTIFICATION_SOURCES + [
    "BrowserUploadFixture", "BrowserLoginFixture", "SkillExecutionUITestSupport", "BrowserWorkspace",
    "ChatSession", "ChatPDFAttachment", "ChatPDFUITestSupport", "ConversationArchiveStore", "BrowserSession", "LearningKeychainStore", "UITestModelFixture", "MCPSettings",
    "LiveModelUITestSupport", "ModelSettings", "LearningStore", "UITestMCPFixture", "MCPSession",
    "MultiSourceResearchSession", "LearningRunContext", "TaskNotificationCenterAdapter", "TaskNotificationStore", "TaskNotificationChatBridge",
]


def main():
    repo = Path(__file__).resolve().parents[1]
    out = Path(tempfile.mkdtemp(prefix="woow-task-notifications-"))
    source = out / "source"
    report = {"schema": 1, "status": "INCOMPLETE", "source_sha256": {}, "checks": [],
              "source_basis": "captured shared working-tree bytes; not a clean-commit claim",
              "native_ios_execution": False, "native_xctest_execution": False,
              "notification_delivery": False, "system_notification_center_access": False,
              "network_or_personal_keychain": False, "production_source_substitutions": False,
              "limitations": ["SwiftUI/UIKit only parsed for iOS, not typechecked or run",
                              "OS permission/banner/sound/tap acceptance belongs to isolated native CI",
                              "independent skill/browser runner integrations remain out of scope"]}

    def save():
        (out / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n")

    def copy(relative):
        data = (repo / relative).read_bytes()
        target = source / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        report["source_sha256"][relative] = hashlib.sha256(data).hexdigest()
        return str(target)

    def run(name, command, timeout=180):
        start = time.monotonic()
        result = subprocess.run(command, cwd=out, capture_output=True, timeout=timeout)
        (out / (name + ".log")).write_bytes(result.stdout + result.stderr)
        check = {"name": name, "exit_code": result.returncode, "seconds": round(time.monotonic() - start, 3)}
        if name.endswith("execute") and result.returncode == 0:
            check["result"] = json.loads(result.stdout)
        report["checks"].append(check)
        save(); print(json.dumps(check), flush=True)
        if result.returncode:
            print("DIAGNOSTIC=" + str(out / (name + ".log")), flush=True)
            raise RuntimeError(name + "_failed")

    print("OUTPUT=" + str(out), flush=True)
    try:
        module_paths = {name: [copy(str(p.relative_to(repo))) for p in sorted((repo / "Sources" / name).glob("*.swift"))]
                        for name, _ in MODULES}
        apps = [copy("Sources/App/" + name + ".swift") for name in APPS]
        view = copy("Sources/App/TaskNotificationSettingsView.swift")
        tests = copy("Tests/AssistantDomainTests/TaskNotificationChecks.swift")
        wrappers = copy("Tests/AssistantDomainTests/TaskNotificationTests.swift")
        core = copy("scripts/CheckTaskNotificationCore.swift")
        app = copy("scripts/CheckTaskNotificationApp.swift")
        copy("scripts/check_task_notifications.py")
        common = ["swiftc", "-swift-version", "5", "-parse-as-library", "-I", str(out), "-L", str(out)]
        for name, deps in MODULES:
            run(name + "-compile", [*common, "-enable-testing", "-emit-module", "-emit-library", "-module-name", name,
                "-emit-module-path", str(out / (name + ".swiftmodule")), *module_paths[name],
                *["-l" + dep for dep in deps], "-o", str(out / ("lib" + name + ".dylib"))])
        binary = out / "core-checks"
        linking = ["-Xlinker", "-rpath", "-Xlinker", str(out)]
        run("core-compile", [*common, "-warnings-as-errors", "-DTASK_NOTIFICATIONS_STANDALONE", "-lAssistantDomain",
                             *linking, tests, core, "-o", str(binary)])
        run("core-execute", [str(binary)], 45)
        run("iOS-syntax-only", ["swiftc", "-frontend", "-parse", "-target", "arm64-apple-ios17.0", "-DDEBUG",
                                *[p for p in apps if "TaskNotification" in p], view, tests, wrappers, app])
        for config, flags in [("Debug", ["-DDEBUG"]), ("Release", [])]:
            binary = out / (config.lower() + "-app-checks")
            run(config + "-adapter-typecheck", ["swiftc", "-swift-version", "5", "-warnings-as-errors", "-typecheck",
                "-I", str(out), *flags, *[p for p in apps if Path(p).stem in ("TaskNotificationCenterAdapter", "TaskNotificationStore", "AppLanguage", "AppLanguageStore", "AppLanguagePreferences", "AppText", "AppLocalizer", "AppNotificationText")]])
            run(config + "-app-compile", [*common, "-DTASK_NOTIFICATIONS_STANDALONE",
                "-DTASK_NOTIFICATIONS_APP_STANDALONE", *flags, *["-l" + name for name, _ in MODULES], *linking,
                *apps, tests, app, "-o", str(binary)])
            run(config + "-app-execute", [str(binary)], 60)
        report["sources_still_current"] = all(hashlib.sha256((repo / p).read_bytes()).hexdigest() == h
                                               for p, h in report["source_sha256"].items())
        report["captured_checks_status"] = "PASS"
        report["changed_sources"] = [p for p, h in report["source_sha256"].items()
                                     if hashlib.sha256((repo / p).read_bytes()).hexdigest() != h]
        report["status"] = "PASS" if report["sources_still_current"] else "SOURCE_CHANGED"
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        report["status"] = "FAIL"
        report["failure"] = "process_deadline" if isinstance(error, subprocess.TimeoutExpired) else str(error)
    finally:
        save(); print("REPORT=" + str(out / "report.json"), flush=True)
    raise SystemExit(0 if report["status"] == "PASS" else 2 if report["status"] == "SOURCE_CHANGED" else 1)


if __name__ == "__main__":
    main()
