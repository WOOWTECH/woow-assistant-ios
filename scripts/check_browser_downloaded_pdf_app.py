#!/usr/bin/env python3
"""Compile real download bridge/App caller and run loopback WKDownload/PDFKit.

No CI, model, external HTTP, personal preferences or permissions. iOS parse is
syntax only. Native hosted XCTest reuses CheckBrowserDownloadedPDFApp.swift.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

MODULES = [("AssistantModels", []), ("AssistantSkills", ["AssistantModels"]),
           ("AssistantBrowser", ["AssistantModels", "AssistantSkills"])]
GROUPS = {"realDownloadAndApprovals", "invalidSourcesAndLimits", "deletionAndHeldRead", "lateWorkerAndDisclosure"}


def main():
    repo = Path(__file__).resolve().parents[1]
    out = Path(tempfile.mkdtemp(prefix="woow-browser-downloaded-pdf-"))
    source = out / "source"
    env = {k: v for k, v in os.environ.items() if not k.startswith(("WOOW_MODEL_", "WOOW_HA_"))}
    report = {"schema_version": 1, "result": "INCOMPLETE", "source_sha256": {}, "checks": [],
              "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
              "source_boundary": "isolated working-tree bytes; hashes identify uncommitted patch",
              "native_ios_typecheck": False, "native_ios_ui": False, "swiftui_typecheck": False,
              "actual_app_execution_caller": True, "external_network_or_model_requests": 0}

    def save():
        (out / "report.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

    def copy(relative):
        data = (repo / relative).read_bytes()
        target = source / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        report["source_sha256"][relative] = hashlib.sha256(data).hexdigest()
        return str(target)

    def run(label, args, timeout=180):
        started = time.monotonic()
        try:
            proc = subprocess.run(args, cwd=out, env=env, capture_output=True, timeout=timeout)
            code, stdout, stderr = proc.returncode, proc.stdout, proc.stderr
        except subprocess.TimeoutExpired as error:
            code, stdout, stderr = 124, error.stdout or b"", error.stderr or b""
        (out / (label + ".log")).write_bytes(stdout + stderr)
        check = {"name": label, "exit_code": code, "seconds": round(time.monotonic() - started, 3)}
        report["checks"].append(check)
        if not code and label.endswith("-run"):
            result = json.loads(stdout)
            assert set(result["groups"]) == GROUPS and result["passed"] == sum(result["groups"].values())
            assert all(type(v) is int and v > 0 for v in result["groups"].values()) and result["failed"] == 0
            assert result["actual_wkdownload"] and result["actual_pdfkit"] and result["actual_app_execution_caller"]
            assert result["external_network_or_model_requests"] == 0 and result["native_ui"] is False
            check["result"] = result
        save()
        print(json.dumps(check, sort_keys=True), flush=True)
        if code:
            raise RuntimeError("check_failed: " + label)

    print("Local evidence:", out, flush=True)
    try:
        copy("scripts/check_browser_downloaded_pdf_app.py")
        modules = {name: [copy(str(p.relative_to(repo))) for p in sorted((repo / "Sources" / name).glob("*.swift"))]
                   for name, _ in MODULES}
        apps = [copy("Sources/App/" + name + ".swift") for name in ("SkillExecutionView", "SkillExecutionUITestSupport")]
        views = [copy("Sources/App/" + name + ".swift") for name in ("BrowserView", "BrowserLibraryView", "BrowserDownloadsView")]
        harness = copy("scripts/CheckBrowserDownloadedPDFApp.swift")
        wrapper = copy("Tests/AssistantBrowserIntegrationTests/BrowserDownloadedPDFIntegrationTests.swift")
        ui = copy("Tests/WoowAssistantUITests/SkillPDFCapabilityUITests.swift")
        copy("Tests/AssistantSkillsTests/SkillExecutionTests.swift")
        resource = copy("Sources/AssistantSkills/Resources/MikaBundledSkills.json")
        for config, flags in [("Debug", ["-DDEBUG"]), ("Release", [])]:
            build = out / config; build.mkdir()
            (build / "MikaBundledSkills.json").write_bytes(Path(resource).read_bytes())
            for name, deps in MODULES:
                run(config + "-" + name + "-build", ["swiftc", "-swift-version", "5", "-parse-as-library", "-enable-testing",
                    *flags, "-emit-module", "-emit-library", "-module-name", name,
                    "-emit-module-path", str(build / (name + ".swiftmodule")), "-I", str(build), "-L", str(build),
                    *modules[name], *["-l" + d for d in deps], "-o", str(build / ("lib" + name + ".dylib"))])
            binary = build / "browser-downloaded-pdf"
            run(config + "-build", ["swiftc", "-swift-version", "5", "-parse-as-library", *flags,
                "-DBROWSER_DOWNLOADED_PDF_APP_STANDALONE", "-I", str(build), "-L", str(build),
                *["-l" + name for name, _ in MODULES], "-Xlinker", "-rpath", "-Xlinker", str(build),
                *apps, harness, "-o", str(binary)])
            run(config + "-iOS-syntax", ["swiftc", "-frontend", "-parse", "-target", "arm64-apple-ios17.0",
                *flags, *apps, *views, harness, wrapper, ui])
            run(config + "-run", [str(binary)], timeout=120)
        report["result"] = "PASS"
    except Exception as error:
        report["result"] = "FAIL"
        report["failure"] = str(error) if isinstance(error, RuntimeError) else type(error).__name__
    finally:
        changed = [p for p, digest in report["source_sha256"].items()
                   if not (repo / p).exists() or hashlib.sha256((repo / p).read_bytes()).hexdigest() != digest]
        for module, _ in MODULES:
            prefix = "Sources/" + module + "/"
            captured = {p for p in report["source_sha256"] if p.startswith(prefix) and p.endswith(".swift")}
            current = {str(p.relative_to(repo)) for p in (repo / prefix).glob("*.swift")}
            changed += sorted(current ^ captured)
        report["changed_sources"] = changed
        if changed:
            report["result"] = "SOURCE_CHANGED"
        save()
        print(json.dumps({"result": report["result"], "report": str(out / "report.json")}), flush=True)
    return 0 if report["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
