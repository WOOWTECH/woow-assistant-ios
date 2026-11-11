#!/usr/bin/env python3
"""Compile exact App sources and run synthetic profile/chat checks on macOS CLT.

No production defaults, Keychain, model endpoint, or user learning file is used.
The temporary report retains source hashes and distinguishes syntax from typecheck.
"""
import argparse
import hashlib
import json
import pathlib
import subprocess
import tempfile
import time


LANGUAGE_APP_SOURCES = ["AppLanguage", "AppLanguageStore", "AppLanguagePreferences", "AppText", "AppLocalizer", "AppMCPText"]

APP_SOURCES = LANGUAGE_APP_SOURCES + [
    "BrowserUploadFixture", "BrowserLoginFixture", "SkillExecutionUITestSupport",
    "BrowserWorkspace", "ChatSession", "ChatPDFAttachment", "ChatPDFUITestSupport", "ConversationArchiveStore", "BrowserSession", "LearningKeychainStore",
    "UITestModelFixture", "MCPSettings", "LiveModelUITestSupport", "ModelSettings",
    "LearningStore", "LearningRunContext", "UITestMCPFixture", "MCPSession", "MultiSourceResearchSession",
]
MODULES = [
    ("AssistantModels", []), ("AssistantMemory", ["AssistantModels"]),
    ("AssistantPersistence", []), ("AssistantMCP", ["AssistantModels"]),
    ("AssistantSkills", ["AssistantModels"]),
    ("AssistantBrowser", ["AssistantModels", "AssistantSkills"]),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--typecheck-only", action="store_true")
    args = parser.parse_args()
    repo = pathlib.Path(__file__).resolve().parent.parent
    out = pathlib.Path(tempfile.mkdtemp(prefix="woow-profile-chat-app-"))
    source = out / "source"
    report = {"schema_version": 1, "checks": [], "source_sha256": {},
              "head_at_start": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
              "source_snapshot_kind": "shared working-tree bytes; not a clean-commit claim",
              "native_ios_typecheck": False, "swiftui_typecheck": False,
              "production_app_source_substitutions": False,
              "network_or_personal_keychain": False}

    def copy(relative):
        original = repo / relative
        target = source / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        data = original.read_bytes()
        target.write_bytes(data)
        report["source_sha256"][relative] = hashlib.sha256(data).hexdigest()
        return str(target)

    def run(label, command, timeout=180):
        start = time.monotonic()
        try:
            result = subprocess.run(command, cwd=repo, capture_output=True, text=True, timeout=timeout)
            output = result.stdout + result.stderr
            code = result.returncode
        except subprocess.TimeoutExpired:
            result = None
            output = "Bounded check exceeded its process deadline.\n"
            code = 124
        (out / (label + ".log")).write_text(output)
        check = {"name": label, "exit_code": code,
                 "seconds": round(time.monotonic() - start, 3)}
        if label.endswith("-run") and code == 0:
            check["result"] = json.loads(result.stdout)
        report["checks"].append(check)
        (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(check), flush=True)
        if code:
            print("Check failed; bounded local diagnostic:", out / (label + ".log"), flush=True)
            raise SystemExit(1)

    print("Local synthetic evidence:", out, flush=True)
    copy("scripts/check_profile_chat_app.py")
    module_paths = {
        name: [copy(str(p.relative_to(repo))) for p in sorted((repo / "Sources" / name).glob("*.swift"))]
        for name, _ in MODULES
    }
    apps = [copy("Sources/App/" + name + ".swift") for name in APP_SOURCES]
    views = [copy("Sources/App/ContentView.swift"), copy("Sources/App/UserProfileToolReviewView.swift"),
             copy("Sources/App/MemoryToolReviewView.swift")]
    harness = None if args.typecheck_only else copy("scripts/CheckProfileChatApp.swift")
    for name, deps in MODULES:
        run(name + "-build", ["swiftc", "-swift-version", "5", "-parse-as-library",
            "-emit-module", "-emit-library", "-module-name", name,
            "-emit-module-path", str(out / (name + ".swiftmodule")),
            "-I", str(out), "-L", str(out), *module_paths[name],
            *["-l" + d for d in deps], "-o", str(out / ("lib" + name + ".dylib"))])
    for config, flags in [("Debug", ["-DDEBUG"]), ("Release", [])]:
        run(config + "-typecheck", ["swiftc", "-swift-version", "5", "-typecheck",
            "-I", str(out), *flags, *apps])
        run(config + "-iOS-syntax", ["swiftc", "-frontend", "-parse",
            "-target", "arm64-apple-ios17.0", *flags, *apps, *views])
        if harness:
            binary = out / ("profile-chat-" + config.lower())
            run(config + "-build", ["swiftc", "-swift-version", "5", "-parse-as-library",
                "-DPROFILE_CHAT_APP_STANDALONE",
                "-I", str(out), "-L", str(out), *["-l" + m for m, _ in MODULES],
                "-Xlinker", "-rpath", "-Xlinker", str(out), *flags,
                *apps, harness, "-o", str(binary)])
            run(config + "-run", [str(binary)], timeout=45)
    report["sources_still_current"] = all(
        hashlib.sha256((repo / name).read_bytes()).hexdigest() == sha
        for name, sha in report["source_sha256"].items())
    report["head_at_finish"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print("PASS; sources_still_current=" + str(report["sources_still_current"]), flush=True)


if __name__ == "__main__":
    main()
