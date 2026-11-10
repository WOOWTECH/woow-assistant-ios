#!/usr/bin/env python3
"""Compile the real discovery App Session; execute shared offline XCTest bodies.

Only the discovery adapter is synthetic. Its WKWebViews are real and never
navigated; candidates pass the real core DOM acceptance via @testable import.
--live additionally runs the actual Session with mounted production adapters:
two fixed public searches, then two cancellations before requests. No retries,
model service, personal WebKit store, or iOS UI execution.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import re
from urllib.parse import urlsplit

from check_profile_chat_app import MODULES


MODULES = [(name, dependencies) for name, dependencies in MODULES
           if name in ("AssistantModels", "AssistantSkills", "AssistantBrowser")]
GROUPS = {"explicitSearchAndInvalidQueries", "orderedOriginSelectionAndApply",
          "lateSuccessCannotOverwriteRestart", "completedResultCancellation", "queryChangesAndLateFailure",
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


LIVE_GROUPS = {"actualResultQueryChange", "actualResultLeaving", "lateCancelledTasks"}
LIVE_STAGES = {"consent", "search", "actual_result", "selection_apply", "query_change", "leave", "late_cancelled_tasks"}
LIVE_FAILURES = {
    "live_consent_required", "unclassified", "session_task_missing", "unconfirmed_result_or_selection",
    "unconfirmed_browser_or_query", "explicit_search_factory_count", "actual_adapter_not_mounted",
    "request_before_session_task", "adapter_privacy_configuration", "provider_search_failed",
    "session_did_not_finish", "provider_status_or_main_request_count", "result_query_binding",
    "candidate_count_or_authority", "actual_dom_missing", "actual_dom_digest_binding", "actual_dom_page_binding",
    "candidate_not_observed_in_actual_dom", "finished_adapter_retains_dom", "ephemeral_store_received_cookies",
    "insufficient_distinct_origins", "single_origin_apply_allowed", "two_origin_selection_rejected",
    "apply_rewrote_observed_candidates", "apply_started_additional_work", "query_change_kept_old_apply_authority",
    "old_ids_reselected_after_query_change", "query_change_started_search", "leave_kept_old_apply_authority",
    "old_ids_reselected_after_leaving", "leave_started_additional_work", "cancel_did_not_revoke_pending_session",
    "cancelled_task_started_provider_request", "late_cancelled_task_published_state", "initial_factory_request",
    "unexpected_total_operations",
}


def parse_live_result(raw, succeeded):
    """Whitelist fixed metadata and at most four genuinely observed public URLs.

    Never retain raw stdout/stderr on an invalid or failed live process.
    """
    def require(condition):
        if not condition:
            raise CheckFailure("invalid_live_result")

    def integer(value, minimum, maximum):
        return type(value) is int and minimum <= value <= maximum

    require(len(raw) <= 64 * 1024)
    try:
        value = json.loads(raw, object_pairs_hook=unique_fields)
        require(isinstance(value, dict))
        keys = {"status", "failure", "stage", "passed", "groups", "observations", "main_load_requests",
                "adapters_created", "seconds", "query", "actual_app_session", "actual_webkit", "fabricated_dom",
                "model_requests", "candidate_body_reads", "personal_webkit_store", "native_ios_execution", "retries"}
        require(set(value) == keys)
        require(value["status"] == ("PASS" if succeeded else "FAIL"))
        require(value["failure"] == "none" if succeeded else value["failure"] in LIVE_FAILURES)
        require(value["stage"] in LIVE_STAGES and value["query"] == "Swift concurrency documentation")
        require(integer(value["passed"], 0, 1000) and integer(value["main_load_requests"], 0, 4)
                and integer(value["adapters_created"], 0, 4))
        require(type(value["seconds"]) in (int, float) and 0 <= value["seconds"] <= 240)
        require(value["actual_app_session"] is True and value["actual_webkit"] is True)
        require(all(value[k] is False for k in ("fabricated_dom", "personal_webkit_store", "native_ios_execution")))
        require(all(integer(value[k], 0, 0) for k in ("model_requests", "candidate_body_reads", "retries")))
        groups = value["groups"]
        require(isinstance(groups, dict) and set(groups) <= LIVE_GROUPS
                and all(integer(n, 1, 1000) for n in groups.values()))
        require(isinstance(value["observations"], list) and len(value["observations"]) <= 2)
        for observation in value["observations"]:
            require(set(observation) == {"query", "provider", "http_status", "main_load_requests", "candidate_count",
                "distinct_origin_count", "html_bytes", "dom_sha256", "observed_at", "selected_public_urls", "selected_dom_indices"})
            require(observation["query"] == value["query"] and observation["provider"] == "duckDuckGoHTML"
                    and integer(observation["http_status"], 200, 200) and integer(observation["main_load_requests"], 1, 1))
            require(integer(observation["candidate_count"], 2, 30)
                    and integer(observation["distinct_origin_count"], 2, observation["candidate_count"])
                    and integer(observation["html_bytes"], 1, 1024 * 1024))
            require(isinstance(observation["dom_sha256"], str) and re.fullmatch(r"[a-f0-9]{64}", observation["dom_sha256"]) is not None)
            require(isinstance(observation["observed_at"], str)
                    and re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", observation["observed_at"]) is not None)
            require(isinstance(observation["selected_dom_indices"], list) and len(observation["selected_dom_indices"]) == 2
                    and len(set(observation["selected_dom_indices"])) == 2
                    and all(integer(i, 0, 9999) for i in observation["selected_dom_indices"]))
            urls = observation["selected_public_urls"]
            require(isinstance(urls, list) and len(urls) == 2)
            origins = set()
            for address in urls:
                require(isinstance(address, str) and len(address.encode("utf-8")) <= 2048
                        and not any(ord(c) < 32 for c in address))
                parsed = urlsplit(address)
                require(parsed.scheme == "https" and parsed.hostname is not None and parsed.username is None
                        and parsed.password is None and not parsed.query and not parsed.fragment)
                origins.add((parsed.hostname, parsed.port or 443))
            require(len(origins) == 2)
        if succeeded:
            require(set(groups) == LIVE_GROUPS and sum(groups.values()) + 2 == value["passed"]
                    and value["main_load_requests"] == 2 and value["adapters_created"] == 4
                    and len(value["observations"]) == 2 and value["stage"] == "late_cancelled_tasks")
        return value
    except (ValueError, TypeError, KeyError):
        raise CheckFailure("invalid_live_result") from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", help="run two fixed public searches through the actual App Session and WebKit")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    out = Path(tempfile.mkdtemp(prefix="woow-source-discovery-app-"))
    source = out / "source"
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(("WOOW_MODEL_TEST_", "WOOW_HA_"))}
    report = {"schema_version": 1, "result": "INCOMPLETE", "checks": [], "source_sha256": {},
              "source_snapshot_kind": "captured shared working-tree bytes; not a clean-commit claim",
              "actual_app_session": False, "core_dom_acceptance": False, "testable_core_import": True,
              "sources_still_current": None,
              "actual_search_service": False, "offline_network_requests": 0, "native_ios_execution": False,
              "live_requested": args.live, "live_attempted": False,
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
        if label == "Live-run":
            check["result"] = parse_live_result(process.stdout, code == 0)
            report["actual_search_service"] = check["result"]["main_load_requests"] > 0
        elif label.endswith("-run") and code == 0:
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
        runner_tests = copy("scripts/test_check_research_source_discovery_app.py")
        modules = {name: [copy(str(path.relative_to(repo))) for path in sorted((repo / "Sources" / name).glob("*.swift"))]
                   for name, _ in MODULES}
        app = copy("Sources/App/ResearchSourceDiscoverySession.swift")
        views = [copy("Sources/App/" + name + ".swift") for name in ("ResearchSourceDiscoveryView", "MultiSourceResearchView")]
        harness = copy("scripts/CheckResearchSourceDiscoveryApp.swift")
        live_harness = copy("scripts/LiveResearchSourceDiscoveryAppSmoke.swift")
        verify_snapshot()
        run("Runner-contract-tests", ["python3", runner_tests], timeout=30)
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
        # Compile live source even in offline mode, but never execute it unless
        # explicitly requested and the entire current source snapshot passed.
        live_binary = out / "Release" / "source-discovery-app-live"
        build = out / "Release"
        run("Live-build", ["swiftc", "-swift-version", "5", "-warnings-as-errors", "-parse-as-library",
            "-I", str(build), "-L", str(build), *["-l" + name for name, _ in MODULES],
            "-Xlinker", "-rpath", "-Xlinker", str(build), app, live_harness, "-o", str(live_binary)])
        expected = {config + "-" + name + "-build" for config in ("Debug", "Release") for name, _ in MODULES} | {
            config + suffix for config in ("Debug", "Release") for suffix in ("-build", "-iOS-syntax", "-run")} | {"Live-build", "Runner-contract-tests"}
        names = [check["name"] for check in report["checks"]]
        if len(names) != len(set(names)) or set(names) != expected or any(check["exit_code"] != 0 for check in report["checks"]):
            raise CheckFailure("incomplete_checks")
        verify_snapshot()
        if args.live:
            report["live_attempted"] = True
            save()
            run("Live-run", [str(live_binary), "--live"], timeout=240)
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
