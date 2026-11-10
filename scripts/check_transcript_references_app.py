#!/usr/bin/env python3
"""Snapshot actual Transcript/App/reference sources; synthetic models and keys only.

Compiles actual App sources on macOS, with no production substitutions. The same
Swift bodies are hosted XCTest methods. iOS parse is explicitly syntax-only.
Source drift is retained as SOURCE_CHANGED, never automatically rerun.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from check_profile_chat_app import APP_SOURCES, MODULES


GROUPS = {"consentCaptureAndCompletion", "switchesAndCapabilityBounds", "frozenEditsAndDestination",
          "revocationJoinsHeldActualTask", "oldRunCannotReplaceNewDelivery"}


def main():
    repo = Path(__file__).resolve().parents[1]
    out = Path(tempfile.mkdtemp(prefix="woow-transcript-references-"))
    source = out / "source"
    env = {k: v for k, v in os.environ.items() if not k.startswith(("WOOW_", "IOS_", "ASC_"))}
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    report = {"schema_version": 1, "status": "INCOMPLETE", "checks": [], "source_sha256": {},
              "head_at_start": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, env=env, text=True).strip(),
              "source_snapshot_kind": "captured working-tree bytes", "native_ios_execution": False,
              "swiftui_typechecked": False, "personal_keychain_used": False, "model_network_requests": 0,
              "production_app_source_substitutions": False, "live_harness_execution": False}

    def save():
        (out / "report.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

    def copy(relative):
        data = (repo / relative).read_bytes()
        target = source / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        report["source_sha256"][relative] = hashlib.sha256(data).hexdigest()
        return str(target)

    def run(name, args, timeout=180):
        started = time.monotonic()
        result = subprocess.run(args, cwd=source, env=env, capture_output=True, timeout=timeout)
        (out / (name + ".log")).write_bytes(result.stdout + result.stderr)
        check = {"name": name, "exit_code": result.returncode, "seconds": round(time.monotonic() - started, 3)}
        if name.endswith("app-run"):
            check["result"] = json.loads(result.stdout)
            if result.returncode == 0:
                value = check["result"]
                if (set(value.get("groups", {})) != GROUPS or value.get("failed") != 0
                        or sum(value["groups"].values()) != value.get("passed")
                        or value.get("model_network_requests") != 0 or value.get("native_ios_ui") is not False
                        or not value.get("actual_app_sources") or not value.get("actual_encrypted_store")):
                    raise RuntimeError("invalid_app_result")
        if name.endswith("core-run") and result.returncode == 0:
            if b"PASS all 17 transcript suites" not in result.stdout or b"FAIL " in result.stdout:
                raise RuntimeError("incomplete_core_result")
            check["suites_passed"] = 17
        report["checks"].append(check); save(); print(json.dumps(check), flush=True)
        if result.returncode:
            raise RuntimeError(name + "_failed")

    print("OUTPUT=" + str(out), flush=True)
    try:
        modules = {name: [copy(str(p.relative_to(repo))) for p in sorted((repo / "Sources" / name).glob("*.swift"))]
                   for name, _ in MODULES}
        apps = [copy("Sources/App/" + name + ".swift") for name in [*APP_SOURCES, "TranscriptSession", "TranscriptUITestSupport"]]
        views = [copy("Sources/App/" + name + ".swift") for name in
                 ["TranscriptView", "TranscriptBrowserView", "MemoryDataView", "SkillCatalogView"]]
        core = [copy(str(p.relative_to(repo))) for p in sorted((repo / "Tests/AssistantSkillsTests").glob("Transcript*.swift"))]
        app = copy("scripts/CheckTranscriptReferencesApp.swift")
        live = copy("scripts/LiveTranscriptSmoke.swift")
        resource = copy("Sources/AssistantSkills/Resources/MikaBundledSkills.json")
        for relative in ["scripts/check_transcript_references_app.py", "scripts/check_profile_chat_app.py",
                         "Tests/WoowAssistantUITests/TranscriptUITests.swift", "Tests/WoowAssistantUITests/LiveTranscriptUITests.swift"]:
            copy(relative)
        probe = subprocess.run(["swiftc", "-typecheck", "-"], input=b"import XCTest\n", cwd=source,
                               env=env, capture_output=True, timeout=30)
        (out / "macOS-XCTest-availability.log").write_bytes(probe.stdout + probe.stderr)
        has_xctest = probe.returncode == 0
        if not has_xctest and b"no such module 'XCTest'" not in probe.stderr:
            raise RuntimeError("unexpected_XCTest_availability_failure")
        report["macos_xctest_wrapper_typecheck_available"] = has_xctest
        report["macos_xctest_wrapper_typecheck"] = "pending" if has_xctest else "UNAVAILABLE: CLT has no XCTest module; no replacement stub used"
        save()
        for config, flags in [("Debug", ["-DDEBUG"]), ("Release", [])]:
            build = out / config; build.mkdir()
            (build / "MikaBundledSkills.json").write_bytes(Path(resource).read_bytes())
            common = ["swiftc", "-swift-version", "5", "-parse-as-library", "-I", str(build), "-L", str(build), *flags]
            for name, dependencies in MODULES:
                run(config + "-" + name + "-compile", [*common, "-enable-testing", "-emit-module", "-emit-library",
                    "-module-name", name, "-emit-module-path", str(build / (name + ".swiftmodule")),
                    *modules[name], *["-l" + d for d in dependencies], "-o", str(build / ("lib" + name + ".dylib"))])
            link = ["-Xlinker", "-rpath", "-Xlinker", str(build)]
            binary = build / "transcript-app"
            run(config + "-app-compile", [*common, "-DTRANSCRIPT_REFERENCES_APP_STANDALONE",
                *["-l" + name for name, _ in MODULES], *link, *apps, app, "-o", str(binary)])
            run(config + "-app-run", [str(binary)], 60)
            # The hosted wrapper follows a different conditional compilation path.
            # Compile against a module made only from the actual captured App files.
            if has_xctest:
                run(config + "-hosted-app-module", [*common, "-enable-testing", "-emit-module", "-module-name", "WoowAssistant",
                    "-emit-module-path", str(build / "WoowAssistant.swiftmodule"), *apps])
                run(config + "-hosted-wrapper-typecheck", ["swiftc", "-swift-version", "5", "-typecheck", *flags,
                    "-I", str(build), app])
            binary = build / "transcript-core"
            run(config + "-core-compile", [*common, "-DTRANSCRIPT_SMOKE", "-lAssistantModels", "-lAssistantSkills",
                *link, *core, "-o", str(binary)])
            run(config + "-core-run", [str(binary), resource], 90)
            if has_xctest:
                run(config + "-core-XCTest-typecheck", ["swiftc", "-swift-version", "5", "-typecheck", *flags,
                    "-I", str(build), *core])
            # Compile the real-HTTP entry point without reading model configuration
            # or executing it. It constructs only TranscriptRuntime, not an App
            # session; the actual App harness above explicitly injects a temp vault.
            run(config + "-live-compile-only", [*common, "-DLOCAL_PROBE", "-lAssistantModels", "-lAssistantSkills",
                *link, live, "-o", str(build / "transcript-live")])
            run(config + "-iOS-syntax-only", ["swiftc", "-frontend", "-parse", "-target", "arm64-apple-ios17.0", *flags,
                *apps, *views, app, *core])
        report["status"] = "PASS"
        if has_xctest:
            report["macos_xctest_wrapper_typecheck"] = "PASS"
    except subprocess.TimeoutExpired:
        report["status"] = "FAIL"; report["failure"] = "bounded_process_deadline"
    except (RuntimeError, ValueError) as error:
        report["status"] = "FAIL"; report["failure"] = str(error)
    changed = [p for p, h in report["source_sha256"].items()
               if not (repo / p).exists() or hashlib.sha256((repo / p).read_bytes()).hexdigest() != h]
    for name, _ in MODULES:
        captured = {p for p in report["source_sha256"] if p.startswith("Sources/" + name + "/") and p.endswith(".swift")}
        current = {str(p.relative_to(repo)) for p in (repo / "Sources" / name).glob("*.swift")}
        changed.extend(sorted(captured.symmetric_difference(current)))
    report["changed_sources"] = sorted(set(changed)); report["sources_still_current"] = not changed
    if changed and report["status"] == "PASS":
        report["status"] = "SOURCE_CHANGED"
    save(); print(json.dumps({"status": report["status"], "report": str(out / "report.json")}), flush=True)
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
