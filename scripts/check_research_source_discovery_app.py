#!/usr/bin/env python3
"""Compile the real discovery App Session; execute shared offline XCTest bodies.

Only the discovery adapter is synthetic. Its WKWebViews are real and never
navigated; candidates pass the real core DOM acceptance via @testable import.
No live search, model, personal WebKit store, or iOS UI execution is claimed.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from check_profile_chat_app import MODULES


MODULES = [(name, dependencies) for name, dependencies in MODULES
           if name in ("AssistantModels", "AssistantSkills", "AssistantBrowser")]
GROUPS = {"explicitSearchAndInvalidQueries", "orderedOriginSelectionAndApply",
          "lateSuccessCannotOverwriteRestart", "queryChangesAndLateFailure",
          "failureCancellationAndExplicitRetry", "runningBlocksSelectionAndDuplicateSearch"}


class CheckFailure(Exception):
    pass


def unique_fields(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise CheckFailure("invalid_result")
        result[key] = value
    return result


def main():
    repo = Path(__file__).resolve().parents[1]
    out = Path(tempfile.mkdtemp(prefix="woow-source-discovery-app-"))
    source = out / "source"
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(("WOOW_MODEL_TEST_", "WOOW_HA_"))}
    report = {"schema_version": 1, "result": "INCOMPLETE", "checks": [], "source_sha256": {},
              "source_snapshot_kind": "captured shared working-tree bytes; not a clean-commit claim",
              "actual_app_session": False, "core_dom_acceptance": False, "testable_core_import": True,
              "sources_still_current": None,
              "actual_search_service": False, "network_requests": 0, "native_ios_execution": False,
              "native_ios_typecheck": False, "swiftui_view_typecheck": False,
              "production_app_source_substitutions": False, "personal_webkit_store": False}

    def head():
        return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, env=environment, text=True).strip()

    def save():
        (out / "report.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

    def copy(relative):
        data = (repo / relative).read_bytes()
        target = source / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        report["source_sha256"][relative] = hashlib.sha256(data).hexdigest()
        return str(target)

    def verify_snapshot():
        for name, _ in MODULES:
            prefix = "Sources/" + name + "/"
            captured = {path for path in report["source_sha256"] if path.startswith(prefix) and path.endswith(".swift")}
            current = {str(path.relative_to(repo)) for path in (repo / prefix).glob("*.swift")}
            if not captured or captured != current:
                raise CheckFailure("source_changed")
        for relative, expected in report["source_sha256"].items():
            for root in (source, repo):
                path = (root / relative).resolve()
                try:
                    path.relative_to(root.resolve())
                    actual = hashlib.sha256(path.read_bytes()).hexdigest()
                except (ValueError, OSError):
                    raise CheckFailure("source_changed") from None
                if actual != expected:
                    raise CheckFailure("source_changed")

    def parse_result(raw):
        if len(raw) > 32 * 1024:
            raise CheckFailure("invalid_result")
        try:
            value = json.loads(raw, object_pairs_hook=unique_fields)
            groups = value["groups"]
            if (type(value["passed"]) is not int or value["passed"] <= 0 or type(value["failed"]) is not int
                    or value["failed"] != 0 or not isinstance(groups, dict) or set(groups) != GROUPS
                    or any(type(count) is not int or count <= 0 for count in groups.values())
                    or sum(groups.values()) != value["passed"]
                    or value.get("actual_app_session") is not True or value.get("core_dom_acceptance") is not True
                    or value.get("actual_search_service") is not False or value.get("native_ios_ui") is not False
                    or type(value.get("network_requests")) is not int or value["network_requests"] != 0):
                raise CheckFailure("invalid_result")
            return {"passed": value["passed"], "failed": 0, "groups": groups, "network_requests": 0}
        except (ValueError, TypeError, KeyError):
            raise CheckFailure("invalid_result") from None

    def run(label, command, timeout=180):
        start = time.monotonic()
        try:
            process = subprocess.run(command, cwd=out, env=environment, capture_output=True, timeout=timeout)
            code = process.returncode
        except subprocess.TimeoutExpired:
            report["checks"].append({"name": label, "exit_code": 124, "failure": "deadline",
                                     "seconds": round(time.monotonic() - start, 3)})
            raise CheckFailure("check_timeout") from None
        check = {"name": label, "exit_code": code, "seconds": round(time.monotonic() - start, 3)}
        report["checks"].append(check)
        if label.endswith("-run") and code == 0:
            check["result"] = parse_result(process.stdout)
            report["actual_app_session"] = True
            report["core_dom_acceptance"] = True
        elif code:
            (out / (label + ".log")).write_bytes(process.stdout + process.stderr)
        save()
        print(json.dumps(check, sort_keys=True), flush=True)
        if code:
            raise CheckFailure("check_failed")

    try:
        report["head_at_start"] = head()
        copy("scripts/check_research_source_discovery_app.py")
        copy("scripts/check_profile_chat_app.py")
        modules = {name: [copy(str(path.relative_to(repo))) for path in sorted((repo / "Sources" / name).glob("*.swift"))]
                   for name, _ in MODULES}
        app = copy("Sources/App/ResearchSourceDiscoverySession.swift")
        views = [copy("Sources/App/" + name + ".swift") for name in ("ResearchSourceDiscoveryView", "MultiSourceResearchView")]
        harness = copy("scripts/CheckResearchSourceDiscoveryApp.swift")
        verify_snapshot()
        for config, flags in [("Debug", ["-DDEBUG"]), ("Release", [])]:
            build = out / config
            build.mkdir()
            for name, dependencies in MODULES:
                run(config + "-" + name + "-build", ["swiftc", "-swift-version", "5", "-parse-as-library",
                    "-enable-testing", *flags, "-emit-module", "-emit-library", "-module-name", name,
                    "-emit-module-path", str(build / (name + ".swiftmodule")), "-I", str(build), "-L", str(build),
                    *modules[name], *["-l" + dependency for dependency in dependencies], "-o", str(build / ("lib" + name + ".dylib"))])
            binary = build / "source-discovery-app"
            run(config + "-build", ["swiftc", "-swift-version", "5", "-parse-as-library", "-DRESEARCH_DISCOVERY_APP_STANDALONE",
                "-I", str(build), "-L", str(build), *["-l" + name for name, _ in MODULES],
                "-Xlinker", "-rpath", "-Xlinker", str(build), *flags, app, harness, "-o", str(binary)])
            run(config + "-iOS-syntax", ["swiftc", "-frontend", "-parse", "-target", "arm64-apple-ios17.0", *flags, app, *views, harness])
            run(config + "-run", [str(binary)], timeout=60)
        expected = {config + "-" + name + "-build" for config in ("Debug", "Release") for name, _ in MODULES} | {
            config + suffix for config in ("Debug", "Release") for suffix in ("-build", "-iOS-syntax", "-run")}
        names = [check["name"] for check in report["checks"]]
        if len(names) != len(set(names)) or set(names) != expected or any(check["exit_code"] != 0 for check in report["checks"]):
            raise CheckFailure("incomplete_checks")
        verify_snapshot()
        report["sources_still_current"] = True
        report["result"] = "PASS"
    except CheckFailure as failure:
        report["result"] = "FAIL"; report["failure"] = str(failure)
        if str(failure) == "source_changed": report["sources_still_current"] = False
    except Exception:
        report["result"] = "FAIL"; report["failure"] = "runner_failure"
    finally:
        if report["source_sha256"]:
            try:
                verify_snapshot()
                report["sources_still_current"] = True
            except CheckFailure:
                report["sources_still_current"] = False
        report["head_at_finish"] = head(); save()
        print(json.dumps({"result": report["result"], "failure": report.get("failure", "none"),
                          "report": str(out / "report.json"), "checks_completed": len(report["checks"]),
                          "sources_still_current": report["sources_still_current"]}, sort_keys=True), flush=True)
    raise SystemExit(0 if report["result"] == "PASS" else 1)


if __name__ == "__main__":
    main()
