#!/usr/bin/env python3
"""Snapshot actual archive/App/notification sources; local synthetic files only."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from check_task_notifications import APPS, MODULES


def main():
    repo = Path(__file__).resolve().parents[1]
    out = Path(tempfile.mkdtemp(prefix="woow-conversation-archive-"))
    source = out / "source"
    env = {k: v for k, v in os.environ.items() if not k.startswith("WOOW_MODEL_TEST_")}
    report = {"schema_version": 1, "status": "INCOMPLETE", "source_sha256": {}, "checks": [],
              "head_at_start": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
              "source_snapshot_kind": "shared working-tree bytes", "network_or_personal_keychain": False,
              "native_ios_execution": False, "swiftui_typechecked": False,
              "production_source_substitutions": False}

    def save():
        (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")

    def copy(relative):
        data = (repo / relative).read_bytes(); target = source / relative
        target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(data)
        report["source_sha256"][relative] = hashlib.sha256(data).hexdigest()
        return str(target)

    def run(name, command, timeout=180):
        started = time.monotonic()
        result = subprocess.run(command, cwd=source, env=env, capture_output=True, timeout=timeout)
        (out / (name + ".log")).write_bytes(result.stdout + result.stderr)
        check = {"name": name, "exit_code": result.returncode, "seconds": round(time.monotonic() - started, 3)}
        if name.endswith("-execute") and result.returncode == 0:
            check["result"] = json.loads(result.stdout)
        report["checks"].append(check); save(); print(json.dumps(check), flush=True)
        if result.returncode:
            raise RuntimeError(name + "_failed")

    print("OUTPUT=" + str(out), flush=True)
    try:
        modules = {name: [copy(str(p.relative_to(repo))) for p in sorted((repo / "Sources" / name).glob("*.swift"))]
                   for name, _ in MODULES}
        apps = [copy("Sources/App/" + name + ".swift") for name in APPS]
        views = [copy("Sources/App/" + name + ".swift") for name in ["ContentView", "ConversationArchiveView"]]
        ui = copy("Tests/WoowAssistantUITests/ConversationArchiveUITests.swift")
        core = copy("Tests/AssistantPersistenceTests/ConversationArchiveTests.swift")
        app = copy("scripts/CheckConversationArchiveApp.swift")
        prior = copy("scripts/CheckProfileChatApp.swift")
        for path in ["scripts/check_conversation_archive_app.py", "scripts/check_task_notifications.py",
                     "scripts/check_profile_chat_app.py", "scripts/check_chat_context_window.py",
                     "Tests/AssistantModelsTests/ChatContextWindowTests.swift"]:
            copy(path)
        common = ["swiftc", "-swift-version", "5", "-parse-as-library", "-I", str(out), "-L", str(out)]
        link = ["-Xlinker", "-rpath", "-Xlinker", str(out)]
        for name, deps in MODULES:
            run(name + "-compile", [*common, "-enable-testing", "-emit-module", "-emit-library", "-module-name", name,
                "-emit-module-path", str(out / (name + ".swiftmodule")), *modules[name],
                *["-l" + d for d in deps], "-o", str(out / ("lib" + name + ".dylib"))])
        binary = out / "archive-core"
        run("core-compile", [*common, "-warnings-as-errors", "-DCONVERSATION_ARCHIVE_STANDALONE", "-lAssistantPersistence",
                             *link, core, "-o", str(binary)])
        run("core-execute", [str(binary)], 45)
        run("existing-context-window", ["python3", str(source / "scripts/check_chat_context_window.py")], 120)
        for config, flags in [("Debug", ["-DDEBUG"]), ("Release", [])]:
            run(config + "-iOS-syntax-only", ["swiftc", "-frontend", "-parse", "-target", "arm64-apple-ios17.0", *flags, *apps, *views, app, ui])
            binary = out / (config + "-archive-app")
            run(config + "-compile", [*common, "-DCONVERSATION_ARCHIVE_APP_STANDALONE", *flags,
                *["-l" + m for m, _ in MODULES], *link, *apps, app, "-o", str(binary)])
            run(config + "-execute", [str(binary)], 60)
            binary = out / (config + "-existing-chat")
            run(config + "-existing-chat-compile", [*common, "-DPROFILE_CHAT_APP_STANDALONE", *flags,
                *["-l" + m for m, _ in MODULES], *link, *apps, prior, "-o", str(binary)])
            run(config + "-existing-chat-execute", [str(binary)], 60)
        report["changed_sources"] = [p for p, h in report["source_sha256"].items() if hashlib.sha256((repo / p).read_bytes()).hexdigest() != h]
        report["sources_still_current"] = not report["changed_sources"]
        report["status"] = "PASS" if report["sources_still_current"] else "SOURCE_CHANGED"
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        report["status"] = "FAIL"
        report["failure"] = "process_deadline" if isinstance(error, subprocess.TimeoutExpired) else str(error)
    save(); print(json.dumps({"status": report["status"], "report": str(out / "report.json")}), flush=True)
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
