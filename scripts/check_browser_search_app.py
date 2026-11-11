#!/usr/bin/env python3
"""Compile actual App sources; isolated manual-search/WebKit validation on macOS.

No personal profile, Keychain or external network. iOS parse is not native proof.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from check_profile_chat_app import APP_SOURCES, MODULES


def main():
    repo = Path(__file__).resolve().parents[1]
    out = Path(tempfile.mkdtemp(prefix="woow-browser-search-check-"))
    source = out / "source"
    report = {"status": "INCOMPLETE", "checks": [], "source_sha256": {},
              "base": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
              "native_ios_execution": False, "native_xctest_execution": False,
              "swiftui_typechecked": False, "production_source_substitutions": False,
              "personal_keychain_or_external_network": False,
              "limitations": ["Controlled simulated HTTPS WebKit documents; outgoing search requests intercepted",
                              "iOS/UIKit/SwiftUI/XCTest syntax only; parent owns native CI"]}

    def save():
        (out / "report.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

    def copy(relative):
        data = (repo / relative).read_bytes()
        target = source / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        report["source_sha256"][relative] = hashlib.sha256(data).hexdigest()
        return str(target)

    def run(name, command, timeout=180):
        started = time.monotonic()
        result = subprocess.run(command, cwd=out, capture_output=True, timeout=timeout,
                                env={k: v for k, v in os.environ.items() if not k.startswith("WOOW_MODEL_TEST_")})
        (out / (name + ".log")).write_bytes(result.stdout + result.stderr)
        row = {"name": name, "exit_code": result.returncode, "seconds": round(time.monotonic() - started, 3)}
        if name.endswith("-run") and result.returncode == 0:
            row["result"] = json.loads(result.stdout)
        report["checks"].append(row)
        save(); print(json.dumps(row), flush=True)
        if result.returncode:
            print("DIAGNOSTIC=" + str(out / (name + ".log")), flush=True)
            raise RuntimeError(name + " failed")

    print("OUTPUT=" + str(out), flush=True)
    try:
        copy("scripts/check_browser_search_app.py")
        copy("scripts/check_profile_chat_app.py")
        modules = {name: [copy(str(p.relative_to(repo))) for p in sorted((repo / "Sources" / name).glob("*.swift"))]
                   for name, _ in MODULES}
        apps = [copy("Sources/App/" + name + ".swift") for name in APP_SOURCES]
        checks = [copy("Tests/AssistantDomainTests/" + name + ".swift") for name in ["BrowserSearchChecks", "BrowserUserSiteModesChecks"]]
        harnesses = [copy("scripts/" + name + ".swift") for name in ["CheckBrowserSearchApp", "CheckBrowserSiteModesApp"]]
        native = [copy(p) for p in ["Sources/App/BrowserView.swift", "Sources/App/BrowserLibraryView.swift", "Sources/App/BrowserSearchSettingsView.swift",
                  "Tests/AssistantDomainTests/BrowserSearchTests.swift", "Tests/AssistantBrowserIntegrationTests/BrowserSearchIntegrationTests.swift",
                  "Tests/WoowAssistantUITests/BrowserSearchUITests.swift"]]
        common = ["swiftc", "-swift-version", "5", "-parse-as-library", "-I", str(out), "-L", str(out)]
        for name, deps in MODULES:
            run(name + "-build", common + ["-emit-module", "-emit-library", "-module-name", name,
                "-emit-module-path", str(out / (name + ".swiftmodule")), *modules[name],
                *["-l" + d for d in deps], "-o", str(out / ("lib" + name + ".dylib"))])
        for config, flags in [("Debug", ["-DDEBUG"]), ("Release", [])]:
            run(config + "-iOS-syntax-only", ["swiftc", "-frontend", "-parse", "-target", "arm64-apple-ios17.0",
                                            *flags, *apps, *native, *checks, *harnesses])
            binary = out / (config.lower() + "-browser-search")
            run(config + "-app-build", common + [*flags, "-DBROWSER_SEARCH_APP_STANDALONE",
                *["-l" + m for m, _ in MODULES], "-Xlinker", "-rpath", "-Xlinker", str(out),
                *apps, *checks, *harnesses, "-o", str(binary)])
            run(config + "-webkit-run", [str(binary)])
        report["sources_still_current"] = all(hashlib.sha256((repo / p).read_bytes()).hexdigest() == h
                                               for p, h in report["source_sha256"].items())
        report["status"] = "PASS" if report["sources_still_current"] else "SOURCES_CHANGED"
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        report["status"] = "FAIL"
        report["failure"] = str(error)
    finally:
        save(); print("REPORT=" + str(out / "report.json"), flush=True)
    raise SystemExit(0 if report["status"] == "PASS" else 1)


if __name__ == "__main__":
    main()
