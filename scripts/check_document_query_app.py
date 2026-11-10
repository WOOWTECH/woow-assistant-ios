#!/usr/bin/env python3
"""Run actual App document-query checks from one captured source snapshot.

Default: synthetic model only; real App settings, PDFKit and FileDocument;
compile the live harness without executing it.
--live additionally consumes model quota using the parent-owned live harness,
only after both local configurations pass and source bytes remain current.
No raw live output or credentials are retained or printed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from check_profile_chat_app import APP_SOURCES, MODULES


PRIVATE_FIELDS = ("WOOW_MODEL_TEST_BASE_URL", "WOOW_MODEL_TEST_MODEL", "WOOW_MODEL_TEST_API_KEY")
GROUPS = {"consentAndExport", "changedAccessBeforeStart", "lateSettingsAndKeyChanges",
          "cancellationAndQuestionChanges", "failureRefusalAndExplicitRetry",
          "correctionAuditAndQuestionReset", "referenceCaptureAndSwitches",
          "referenceEditsStayFrozen", "referenceRevocationStopsActualTask"}
LOCAL_HARNESS = "scripts/CheckDocumentQueryApp.swift"
LIVE_HARNESS = "scripts/LiveDocumentQueryAppSmoke.swift"
RESOURCE = "Sources/AssistantSkills/Resources/MikaBundledSkills.json"
REQUIRED_CHECKS = {config + "-" + module + "-build" for config in ("Debug", "Release") for module, _ in MODULES} | {
    config + suffix for config in ("Debug", "Release") for suffix in ("-build", "-run", "-iOS-syntax")} | {"Live-build"}


class CheckFailure(Exception):
    """Fixed classification only; never contains subprocess output."""


def unique_fields(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise CheckFailure("invalid_result")
        result[key] = value
    return result


def clean_environment():
    # Credentials for adjacent live harnesses must not leak into compilers or
    # synthetic tests either. Preserve only the three requested fields for live.
    return {key: value for key, value in os.environ.items()
            if key not in PRIVATE_FIELDS and not key.startswith("WOOW_HA_") and not key.startswith("WOOW_MODEL_TEST_")}


def local_result(raw):
    if len(raw) > 32 * 1024:
        raise CheckFailure("invalid_local_result")
    try:
        value = json.loads(raw, object_pairs_hook=unique_fields)
        groups = value["groups"]
        if (type(value["passed"]) is not int or value["passed"] <= 0 or type(value["failed"]) is not int
                or value["failed"] != 0 or not isinstance(groups, dict) or set(groups) != GROUPS
                or any(type(count) is not int or count <= 0 for count in groups.values())
                or sum(groups.values()) != value["passed"]
                or any(value.get(field) is not True for field in ("actual_app_sources", "actual_pdfkit", "actual_file_document"))
                or value.get("native_ios_ui") is not False or type(value.get("model_network_requests")) is not int
                or value["model_network_requests"] != 0):
            raise CheckFailure("invalid_local_result")
        return {"passed": value["passed"], "failed": 0, "groups": groups, "model_network_requests": 0}
    except (ValueError, KeyError, TypeError):
        raise CheckFailure("invalid_local_result") from None


def live_result(raw):
    # Whitelist fixed counters/categories; do not trust arbitrary stdout as a
    # report even when the child exits successfully.
    if len(raw) > 32 * 1024:
        raise CheckFailure("invalid_live_result")
    try:
        value = json.loads(raw, object_pairs_hook=unique_fields)
        allowed_failures = {"none", "missingConfiguration", "pdfCreation", "extraction", "source", "consent",
                            "deadline", "incomplete", "answer", "citations", "export", "preservation", "budget", "unknown"}
        model_failures = {"none", "httpRejected", "timedOut", "transportFailure", "incompleteResponse", "cancelled", "modelFailure"}
        if (not isinstance(value, dict) or value.get("result") not in ("PASS", "FAIL")
                or value.get("failure") not in allowed_failures or value.get("model_failure") not in model_failures
                or any(type(value.get(key)) is not int or not 0 <= value[key] <= 12 for key in ("model_calls", "model_responses"))
                or value["model_responses"] > value["model_calls"]
                or type(value.get("seconds")) not in (int, float) or not 0 <= value["seconds"] <= 240
                or any(value.get(key) is not True for key in ("actual_model", "actual_pdfkit", "synthetic_source_only"))
                or value.get("native_ios_ui") is not False):
            raise CheckFailure("invalid_live_result")
        if value["result"] == "PASS" and (value["failure"] != "none" or value["model_failure"] != "none"
                or not 4 <= value["model_calls"] == value["model_responses"] <= 12):
            raise CheckFailure("invalid_live_result")
        return {key: value[key] for key in ("result", "failure", "model_calls", "model_responses", "model_failure", "seconds")}
    except (ValueError, KeyError, TypeError):
        raise CheckFailure("invalid_live_result") from None


def verify_snapshot(source, repo, hashes):
    # Adding a Swift file changes a module even if every previously copied file
    # stayed identical. Reject that drift as well as edits/deletions.
    for module, _ in MODULES:
        prefix = "Sources/" + module + "/"
        captured = {path for path in hashes if path.startswith(prefix) and path.endswith(".swift")}
        if captured:
            current = {str(path.relative_to(repo)) for path in (repo / prefix).glob("*.swift")}
            if captured != current:
                raise CheckFailure("source_changed")
    for relative, expected in hashes.items():
        for root in (source, repo):
            path = (root / relative).resolve()
            try:
                path.relative_to(root.resolve())
                actual = hashlib.sha256(path.read_bytes()).hexdigest()
            except (ValueError, OSError):
                raise CheckFailure("source_changed") from None
            if actual != expected:
                raise CheckFailure("source_changed")


def verify_local_checks(checks):
    names = [check["name"] for check in checks]
    if len(names) != len(set(names)) or not REQUIRED_CHECKS.issubset(names):
        raise CheckFailure("incomplete_local_checks")
    for check in checks:
        if check["name"] in REQUIRED_CHECKS and check.get("exit_code") != 0:
            raise CheckFailure("incomplete_local_checks")
    for config in ("Debug", "Release"):
        result = next(check for check in checks if check["name"] == config + "-run").get("result")
        if not result or set(result.get("groups", {})) != GROUPS or result.get("failed") != 0:
            raise CheckFailure("incomplete_local_checks")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", help="After offline checks, run actual model requests with supplied test credentials")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    out = Path(tempfile.mkdtemp(prefix="woow-document-query-app-"))
    source = out / "source"
    build_env = clean_environment()
    private = {key: os.environ.get(key, "") for key in PRIVATE_FIELDS}
    report = {"schema_version": 1, "result": "INCOMPLETE", "checks": [], "source_sha256": {},
              "source_snapshot_kind": "captured shared working-tree bytes; not a clean-commit claim",
              "native_ios_execution": False, "native_ios_typecheck": False, "swiftui_view_typecheck": False,
              "file_document_typechecked": False, "production_app_source_substitutions": False,
              "model_access_source": "Sources/App/ChatSession.swift", "live_requested": args.live,
              "live_attempted": False, "personal_keychain_used": False}

    def head():
        return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, env=build_env, text=True).strip()

    def save():
        (out / "report.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

    def copy(relative):
        data = (repo / relative).read_bytes()
        target = source / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        report["source_sha256"][relative] = hashlib.sha256(data).hexdigest()
        return str(target)

    def run(label, command, timeout=180, live=False):
        start = time.monotonic()
        environment = dict(build_env)
        if live:
            environment.update(private)
        try:
            process = subprocess.run(command, cwd=out, env=environment, capture_output=True, timeout=timeout)
            code = process.returncode
        except subprocess.TimeoutExpired:
            report["checks"].append({"name": label, "exit_code": 124, "failure": "deadline",
                                     "seconds": round(time.monotonic() - start, 3)})
            raise CheckFailure("live_timeout" if live else "local_timeout") from None
        check = {"name": label, "exit_code": code, "seconds": round(time.monotonic() - start, 3)}
        report["checks"].append(check)
        if live:
            # Never write stdout/stderr from actual HTTP execution, including a
            # crashing or unexpectedly verbose child. Only fixed fields survive.
            check["result"] = live_result(process.stdout)
        elif label.endswith("-run") and code == 0:
            check["result"] = local_result(process.stdout)
        elif code:
            # Offline compiler/test diagnostics contain only captured synthetic
            # inputs. Keep them local, never echo them into fixed JSON output.
            (out / (label + ".log")).write_bytes(process.stdout + process.stderr)
        save()
        print(json.dumps(check, sort_keys=True), flush=True)
        if code or (live and check["result"]["result"] != "PASS"):
            raise CheckFailure("live_check_failed" if live else "local_check_failed")

    try:
        report["head_at_start"] = head()
        copy("scripts/check_document_query_app.py")
        copy("scripts/check_profile_chat_app.py")
        modules = {name: [copy(str(path.relative_to(repo))) for path in sorted((repo / "Sources" / name).glob("*.swift"))]
                   for name, _ in MODULES}
        if any(not paths for paths in modules.values()):
            raise CheckFailure("missing_module_sources")
        apps = [copy("Sources/App/" + name + ".swift") for name in [*APP_SOURCES, "DocumentQuerySession", "SkillExecutionView"]]
        views = [copy("Sources/App/DocumentQueryView.swift")]
        harness = copy(LOCAL_HARNESS)
        live_harness = copy(LIVE_HARNESS)
        resource = copy(RESOURCE)
        verify_snapshot(source, repo, report["source_sha256"])
        for config, flags in [("Debug", ["-DDEBUG"]), ("Release", [])]:
            build = out / config
            build.mkdir()
            (build / "MikaBundledSkills.json").write_bytes(Path(resource).read_bytes())
            for name, dependencies in MODULES:
                run(config + "-" + name + "-build", ["swiftc", "-swift-version", "5", "-parse-as-library",
                    *flags, "-emit-module", "-emit-library", "-module-name", name,
                    "-emit-module-path", str(build / (name + ".swiftmodule")), "-I", str(build), "-L", str(build),
                    *modules[name], *["-l" + dependency for dependency in dependencies], "-o", str(build / ("lib" + name + ".dylib"))])
            common = ["swiftc", "-swift-version", "5", "-parse-as-library", "-DSKILL_EXECUTION_EXPORT_CHECKS",
                      "-I", str(build), "-L", str(build), *["-l" + name for name, _ in MODULES],
                      "-Xlinker", "-rpath", "-Xlinker", str(build), *flags]
            binary = build / "document-query-app"
            run(config + "-build", [*common, "-DDOCUMENT_QUERY_APP_STANDALONE", *apps, harness, "-o", str(binary)])
            run(config + "-iOS-syntax", ["swiftc", "-frontend", "-parse", "-target", "arm64-apple-ios17.0", *flags, *apps, *views, harness])
            run(config + "-run", [str(binary)], timeout=60)
        verify_snapshot(source, repo, report["source_sha256"])
        report["local_debug_release_passed"] = True
        report["file_document_typechecked"] = True
        # Compile the parent-owned real-model harness without credentials even
        # in offline mode; --live is the only path that executes this binary.
        binary = out / "Release" / "live-document-query-app"
        run("Live-build", [*common, *apps, live_harness, "-o", str(binary)])
        verify_local_checks(report["checks"])
        verify_snapshot(source, repo, report["source_sha256"])
        report["sources_still_current"] = True
        if args.live:
            if not all(private.values()):
                raise CheckFailure("missing_live_configuration")
            # The Release modules were freshly built above from the SAME copied
            # bytes and passed the local executable. No external dylib/report is
            # accepted; the live harness was captured before any compilation.
            verify_local_checks(report["checks"])
            verify_snapshot(source, repo, report["source_sha256"])
            report["live_attempted"] = True
            save()
            run("Live-run", [str(binary)], timeout=240, live=True)
        verify_snapshot(source, repo, report["source_sha256"])
        report["result"] = "PASS"
    except CheckFailure as failure:
        report["result"] = "FAIL"
        report["failure"] = str(failure)
        if str(failure) == "source_changed":
            report["sources_still_current"] = False
    except Exception:
        report["result"] = "FAIL"
        report["failure"] = "runner_failure"
    finally:
        report["head_at_finish"] = head()
        save()
        print(json.dumps({"result": report["result"], "failure": report.get("failure", "none"),
                          "report": str(out / "report.json"), "checks_completed": len(report["checks"]),
                          "live_attempted": report["live_attempted"], "sources_still_current": report.get("sources_still_current", False)}, sort_keys=True), flush=True)
    raise SystemExit(0 if report["result"] == "PASS" else 1)


if __name__ == "__main__":
    main()
