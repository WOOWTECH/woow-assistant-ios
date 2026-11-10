#!/usr/bin/env python3
"""Run actual replay App checks against a pinned commit plus ONLY three owned files.

No live model, personal store, production defaults, or replacement App types.
The isolated source boundary deliberately excludes concurrent shared-tree edits.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import runpy
import subprocess
import tarfile
import tempfile
import time

OWNED = ["Sources/App/BrowserSession.swift", "scripts/CheckReplayReferencesApp.swift",
         "scripts/check_replay_references_app.py"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True, help="exact coherent integration base commit")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    base = subprocess.check_output(["git", "rev-parse", "--verify", args.base + "^{commit}"], cwd=repo, text=True).strip()
    out = Path(tempfile.mkdtemp(prefix="woow-replay-reference-app-")).resolve()
    source = out / "source"
    source.mkdir()
    report = {"status": "INCOMPLETE", "base_commit": base,
              "source_boundary": "exact base commit plus only owned working-tree overlay files",
              "overlay_files": OWNED, "source_sha256": {}, "checks": [],
              "actual_mac_webkit": True, "actual_encrypted_store": True,
              "synthetic_model_transport": True,
              "production_source_substitutions": False, "live_model_calls": 0,
              "external_network_requests": 0, "native_ios_execution": False,
              "warnings_policy": "owned-source syntax and pure browser regressions use warnings-as-errors; full macOS App/module builds retain existing CLT WebKit actor/API warnings; iOS syntax retains missing iOS sysroot warning",
              "context_ceiling": {"new_for_replay": True, "characters": 120000, "encoded_utf8_bytes": 480000},
              "unchanged_route_limits": {"steps": 13, "seconds": 180, "answer_calls": 1, "judge_calls": 1},
              "citation_scope": "saved-reference/source-ledger separation and independent judge evidence validation; no arbitrary answer citation parser"}

    def save():
        (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")

    def path(relative):
        data = (source / relative).read_bytes()
        report["source_sha256"][relative] = hashlib.sha256(data).hexdigest()
        return str(source / relative)

    def run(name, command, timeout=180):
        start = time.monotonic()
        result = subprocess.run(command, cwd=source, capture_output=True, timeout=timeout)
        (out / (name + ".log")).write_bytes(result.stdout + result.stderr)
        row = {"name": name, "exit_code": result.returncode, "seconds": round(time.monotonic() - start, 3)}
        if name.endswith("-run") and result.returncode == 0:
            if name == "research-regression-run":
                match = re.search(rb"PASS research native checks: (\d+) assertions", result.stdout)
                if not match: raise RuntimeError("missing_research_summary")
                row["result"] = {"passed": int(match.group(1)), "failed": 0}
            elif name == "website-regression-run":
                match = re.search(rb"Website learning: (\d+) offline assertions passed", result.stdout)
                if not match: raise RuntimeError("missing_website_summary")
                row["result"] = {"passed": int(match.group(1)), "failed": 0}
            else:
                row["result"] = json.loads(result.stdout)
        report["checks"].append(row); save()
        print(json.dumps(row), flush=True)
        if result.returncode: raise RuntimeError(name + "_failed")

    print("REPORT=" + str(out / "report.json"), flush=True)
    try:
        archive = subprocess.check_output(["git", "archive", base, "Sources", "Tests", "scripts"], cwd=repo)
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            for member in tar.getmembers():
                target = (source / member.name).resolve()
                if source not in target.parents or not (member.isdir() or member.isfile()):
                    raise RuntimeError("unsafe_archive_member")
            tar.extractall(source)
        for relative in OWNED:
            (source / relative).write_bytes((repo / relative).read_bytes())
            path(relative)
        # The list is from the pinned base, not another agent's in-flight checker.
        config = runpy.run_path(path("scripts/check_profile_chat_app.py"))
        modules = config["MODULES"]
        module_paths = {name: [path(str(p.relative_to(source))) for p in sorted((source / "Sources" / name).glob("*.swift"))] for name, _ in modules}
        apps = [path("Sources/App/" + name + ".swift") for name in config["APP_SOURCES"]]
        caller = path("Sources/App/WebsiteDataView.swift")
        harness = path("scripts/CheckReplayReferencesApp.swift")
        single_site = path("scripts/CheckLearningRunContextApp.swift")
        research = path("Tests/AssistantDomainTests/WebResearchRunnerTests.swift")
        website = path("Tests/AssistantDomainTests/WebsiteLearningTests.swift")
        for name, deps in modules:
            run(name + "-build", ["swiftc", "-swift-version", "5", "-parse-as-library", "-emit-module", "-emit-library", "-module-name", name,
                "-emit-module-path", str(out / (name + ".swiftmodule")), "-I", str(out), "-L", str(out),
                *module_paths[name], *["-l" + d for d in deps], "-o", str(out / ("lib" + name + ".dylib"))])
        common = ["swiftc", "-swift-version", "5", "-parse-as-library", "-I", str(out), "-L", str(out),
                  *["-l" + m for m, _ in modules], "-Xlinker", "-rpath", "-Xlinker", str(out)]
        binary = out / "research-regression"
        run("research-regression-build", common + ["-warnings-as-errors", "-DWEB_RESEARCH_SMOKE", research, "-o", str(binary)])
        run("research-regression-run", [str(binary)], 45)
        browser_files = [path("Sources/AssistantBrowser/" + name) for name in ["BrowserContracts.swift", "BrowserPolicy.swift"]]
        browser_files += [str(p) for pattern in ["WebsiteKnowledge*.swift", "WebRoute*.swift"] for p in sorted((source / "Sources/AssistantBrowser").glob(pattern))]
        binary = out / "website-regression"
        run("website-regression-build", common + ["-warnings-as-errors", "-DWEBSITE_LEARNING_HARNESS", *browser_files, website, "-o", str(binary)])
        run("website-regression-run", [str(binary)], 45)
        for config, flags in [("Debug", ["-DDEBUG"]), ("Release", [])]:
            run(config + "-owned-syntax", ["swiftc", "-frontend", "-parse", "-warnings-as-errors", *flags, path("Sources/App/BrowserSession.swift"), harness])
            run(config + "-iOS-syntax", ["swiftc", "-frontend", "-parse", "-target", "arm64-apple-ios17.0", *flags, *apps, caller, harness])
            binary = out / ("replay-" + config)
            run(config + "-build", common + flags + ["-DREPLAY_REFERENCE_APP_STANDALONE", *apps, harness, "-o", str(binary)])
            run(config + "-run", [str(binary)], 450)
            binary = out / ("single-site-" + config)
            run(config + "-single-site-build", common + flags + ["-DLEARNING_RUN_APP_STANDALONE", *apps, single_site, "-o", str(binary)])
            run(config + "-single-site-run", [str(binary)], 450)
        report["overlay_still_current"] = all(hashlib.sha256((repo / p).read_bytes()).hexdigest() == report["source_sha256"][p] for p in OWNED)
        report["status"] = "PASS" if report["overlay_still_current"] else "OVERLAY_CHANGED"
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        report["status"] = "FAIL"
        report["failure"] = "process_deadline" if isinstance(error, subprocess.TimeoutExpired) else str(error)
    finally:
        save(); print("REPORT=" + str(out / "report.json"), flush=True)
    raise SystemExit(0 if report["status"] == "PASS" else 1)


if __name__ == "__main__":
    main()
