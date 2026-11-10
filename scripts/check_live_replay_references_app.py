#!/usr/bin/env python3
"""Build from the accepted replay snapshot; only --live spends model quota.

Use existing WOOW_MODEL_TEST_{BASE_URL,MODEL,API_KEY} environment configuration.
The new replay task has one opt-in invocation, no retry, and <=8 client attempts.
Raw runtime stdout/stderr is never persisted; only strict whitelisted JSON survives.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import runpy
import subprocess
import tempfile
import time

HARNESS = "scripts/LiveReplayReferencesAppSmoke.swift"
CHECKER = "scripts/check_live_replay_references_app.py"
TESTS = "scripts/test_check_live_replay_references_app.py"
PRIVATE = ("WOOW_MODEL_TEST_BASE_URL", "WOOW_MODEL_TEST_MODEL", "WOOW_MODEL_TEST_API_KEY")
ROOTS = ["https://www.iana.org/domains/reserved", "https://www.iana.org/help/example-domains"]
FAILURES = {"none", "configuration", "sources", "deadline", "inputBoundary", "modelBudget",
            "modelFailure", "incomplete", "preference", "currentPriority", "judgment", "storage", "unknown"}
ERRORS = {"invalidConfiguration", "redirectRejected", "httpStatus", "invalidResponse", "incompleteResponse",
          "responseTooLarge", "consumerTooSlow", "timedOut", "transportFailure"}
FIRST_REPORT_SHA256 = "b17bffd357f321b2efc3e44fb7fca92a97cc1baef712d1e7abfcc2bcba114c29"
CASE_CONTRACT_SHA256 = "43c6f93652b49c38d38d74730159e6f8b296dc1be9cc6cbd0112a234c56d3257"


class CheckFailure(Exception):
    pass


def require(value):
    if not value:
        raise CheckFailure("invalid_report")


def unique_fields(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result)
        result[key] = value
    return result


def integer(value, maximum):
    return type(value) is int and 0 <= value <= maximum


def sha(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def validate_diagnostic(value):
    bools = {"storeAvailable", "storeErrorPresent", "browserErrorPresent", "referenceValid", "goalUnchanged",
             "routeIdentityUnchanged", "observationsNewerThanRoute", "parserReplayMatched"}
    counts = {"wireEvidenceCount", "quotesAbsentFromObservation", "quotesContainingURLAlias", "productionCitationCount"}
    require(set(value) == bools | counts | {"learningStatus", "goalSHA256", "wireOutcome", "productionOutcome", "productionSkipReason"})
    require(all(type(value[k]) is bool for k in bools))
    require(all(integer(value[k], 1024) for k in counts))
    require(value["learningStatus"] in {"saved", "writeFailed", "notConfirmed", "absent", "other"})
    require(sha(value["goalSHA256"]))
    require(value["wireOutcome"] in {"done", "partial", "not_possible", "unknown", "unrecognized", "undecodable"})
    require(value["productionOutcome"] in {"done", "partial", "notPossible", "unknown", "unavailable"})
    require(value["productionSkipReason"] in {"none", "unavailable", "replayFailed", "ineligible", "invalidTrajectory", "unsafeEvidence",
            "noGroundedEvidence", "judgeUnavailable", "invalidJudgment", "tooFewActions", "draftDisabled", "draftUnavailable", "invalidDraft", "nameTaken"})
    if value["productionOutcome"] != "unavailable": require(value["parserReplayMatched"])


def validate_live(raw, diagnostic_only=False):
    """Reject extra fields, response text, unknown URLs/errors and inconsistent counts."""
    require(len(raw) <= 32768)
    try:
        report = json.loads(raw, object_pairs_hook=unique_fields)
        require(set(report) == {"passed", "failure", "preparation", "cases", "clientAttempts", "clientResponses", "milliseconds"})
        require(type(report["passed"]) is bool and report["failure"] in FAILURES)
        require(integer(report["clientAttempts"], 8) and integer(report["clientResponses"], report["clientAttempts"]))
        require(integer(report["milliseconds"], 540000))

        def pages(rows):
            require(type(rows) is list and len(rows) <= 2)
            for index, row in enumerate(rows):
                require(set(row) == {"index", "url", "textSHA256", "quoteSHA256", "textCharacters", "capturedAt"})
                require(type(row["index"]) is int and row["index"] == index and row["url"] == ROOTS[index])
                require(sha(row["textSHA256"]) and sha(row["quoteSHA256"]))
                require(integer(row["textCharacters"], 8000) and row["textCharacters"] > 0)
                require(type(row["capturedAt"]) in (int, float) and math.isfinite(row["capturedAt"]) and 0 < row["capturedAt"] < 253402300799)

        pages(report["preparation"])
        case_ids = ["currentPriority"] if diagnostic_only else ["savedPreference", "currentPriority"]
        require(type(report["cases"]) is list and len(report["cases"]) <= len(case_ids))
        for index, row in enumerate(report["cases"]):
            fields = {"id", "passed", "failure", "clientAttempts", "clientResponses", "modelErrors", "answerInputVerified", "judgeLedgerVerified",
                      "expectedPrefixMatched", "startsWithSavedPrefix", "startsWithCurrentPrefix", "observedURLStringsMentioned",
                      "routeSuccessDelta", "encryptedReadbackVerified", "referencesUnchanged", "observations", "milliseconds"}
            if "diagnostic" in row:
                require(diagnostic_only); validate_diagnostic(row["diagnostic"]); fields |= {"diagnostic"}
            require(set(row) in (fields, fields | {"answerSHA256"}))
            require(row["id"] == case_ids[index] and row["failure"] in FAILURES)
            for name in ["passed", "answerInputVerified", "judgeLedgerVerified", "expectedPrefixMatched", "startsWithSavedPrefix",
                         "startsWithCurrentPrefix", "encryptedReadbackVerified", "referencesUnchanged"]:
                require(type(row[name]) is bool)
            require(integer(row["clientAttempts"], 2) and integer(row["clientResponses"], row["clientAttempts"]))
            require(integer(row["observedURLStringsMentioned"], 2) and integer(row["routeSuccessDelta"], 1) and integer(row["milliseconds"], 540000))
            if "answerSHA256" in row: require(sha(row["answerSHA256"]))
            pages(row["observations"])
            require(type(row["modelErrors"]) is list and len(row["modelErrors"]) <= row["clientAttempts"] - row["clientResponses"])
            for error in row["modelErrors"]:
                require(set(error) == {"kind", "statusCode"} and error["kind"] in ERRORS)
                require(type(error["statusCode"]) is int and
                        (error["statusCode"] == 0 or (error["kind"] == "httpStatus" and 100 <= error["statusCode"] <= 599)))
            if row["passed"]:
                require(row["failure"] == "none" and row["clientAttempts"] == row["clientResponses"] == 2)
                require(row["answerInputVerified"] and row["judgeLedgerVerified"] and row["expectedPrefixMatched"])
                require(row["encryptedReadbackVerified"] and row["referencesUnchanged"] and row["routeSuccessDelta"] == 1)
                require(row["observedURLStringsMentioned"] == 2)
                require(len(row["observations"]) == 2 and "answerSHA256" in row)
                require(row["startsWithSavedPrefix"] == (row["id"] == "savedPreference") and row["startsWithCurrentPrefix"] == (row["id"] == "currentPriority"))
                if diagnostic_only:
                    require("diagnostic" in row and row["diagnostic"]["parserReplayMatched"])
                    require(row["diagnostic"]["productionOutcome"] == "done" and row["diagnostic"]["learningStatus"] == "saved")
            else:
                require(row["failure"] != "none" and index == len(report["cases"]) - 1)
        require(sum(c["clientAttempts"] for c in report["cases"]) == report["clientAttempts"])
        require(sum(c["clientResponses"] for c in report["cases"]) == report["clientResponses"])
        if report["passed"]:
            require(report["failure"] == "none" and len(report["preparation"]) == 2 and len(report["cases"]) == len(case_ids) and all(c["passed"] for c in report["cases"]))
        else:
            require(report["failure"] != "none")
        return report
    except (ValueError, KeyError, TypeError, AttributeError, OverflowError):
        raise CheckFailure("invalid_report") from None


def clean_environment(environment):
    return {key: value for key, value in environment.items() if key in
            {"PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "SDKROOT", "DEVELOPER_DIR"}}


def read_snapshot(root, repo):
    root = root.resolve()
    raw = (root / "report.json").read_bytes()
    require(len(raw) <= 256 * 1024)
    report = json.loads(raw, object_pairs_hook=unique_fields)
    require(report["status"] == "PASS" and report["overlay_still_current"] is True)
    checks = {c["name"] for c in report["checks"] if c["exit_code"] == 0}
    require({"Debug-build", "Debug-run", "Release-build", "Release-run"}.issubset(checks))
    captured = {}
    for relative, expected in report["source_sha256"].items():
        path = (root / "source" / relative).resolve()
        require(path.is_relative_to(root / "source") and sha(expected))
        data = path.read_bytes()
        require(hashlib.sha256(data).hexdigest() == expected)
        captured[relative] = data
    browser = "Sources/App/BrowserSession.swift"
    require(captured[browser] == (repo / browser).read_bytes())
    return report, captured, hashlib.sha256(raw).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", type=Path, required=True)
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--attempt-record", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--diagnostic-current-priority", action="store_true")
    parser.add_argument("--previous-report", type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    out = Path(tempfile.mkdtemp(prefix="woow-live-replay-reference-")).resolve()
    source = out / "source"; source.mkdir()
    environment = clean_environment(os.environ)
    private = {key: os.environ.get(key, "") for key in PRIVATE}
    report = {"status": "INCOMPLETE", "checks": [], "source_sha256": {}, "live_requested": args.live, "live_attempted": False,
              "maximum_total_HTTP_client_attempts": 8, "blind_retries": 0, "per_route_deadline_seconds": 180,
              "process_deadline_seconds": 540, "synthetic_references_only": True, "actual_encrypted_store": True,
              "actual_public_WebKit_pages": ROOTS, "native_ios_execution": False, "product_files_modified": False,
              "raw_request_response_error_logs": False,
              "provenance_scope": "actual public page observations and independent production judge route receipt; free-form answer URL presence and prefix are not exact semantic citation proof"}
    report["diagnostic_current_priority_only"] = args.diagnostic_current_priority
    prior_attempts = prior_responses = 0

    def save():
        data = json.dumps(report, indent=2, sort_keys=True) + "\n"
        (out / "report.json").write_text(data)
        if args.output: args.output.write_text(data)

    def run(name, command, timeout=180, live=False):
        started = time.monotonic()
        result = subprocess.run(command, capture_output=True, env={**environment, **(private if live else {})}, timeout=timeout)
        row = {"name": name, "exit_code": result.returncode, "seconds": round(time.monotonic() - started, 3)}
        if live:
            row["result"] = validate_live(result.stdout, diagnostic_only=args.diagnostic_current_priority)
        elif name == "publication-tests" and result.returncode == 0:
            match = re.search(rb"Ran (\d+) tests", result.stderr)
            require(match is not None)
            row["tests_passed"] = int(match.group(1))
        elif name == "offline-preflight":
            require(len(result.stdout) < 1024)
            row["result"] = json.loads(result.stdout, object_pairs_hook=unique_fields)
            require(set(row["result"]) == {"passed", "checks", "actualHTTPAttempts"})
            require(row["result"]["passed"] is True and integer(row["result"]["checks"], 100) and row["result"]["checks"] >= 13)
            require(type(row["result"]["actualHTTPAttempts"]) is int and row["result"]["actualHTTPAttempts"] == 0)
        elif name == "harness-build":
            warnings = [line for line in result.stderr.decode(errors="replace").splitlines() if "warning:" in line and Path(HARNESS).name in line]
            row["harness_warnings"] = len(warnings)
            if warnings:
                (out / (name + ".log")).write_bytes(result.stdout + result.stderr) # Secret-free compiler output only.
                raise CheckFailure("harness_warning")
        if result.returncode and not live:
            (out / (name + ".log")).write_bytes(result.stdout + result.stderr) # Compiler/preflight never receives private config.
        report["checks"].append(row); save()
        print(json.dumps({key: row[key] for key in ["name", "exit_code", "seconds"]}), flush=True)
        if result.returncode or (live and not row["result"]["passed"]):
            raise CheckFailure("live_failed" if live else "preflight_failed")

    print("REPORT=" + str(out / "report.json"), flush=True)
    try:
        if args.diagnostic_current_priority:
            require(args.previous_report is not None)
            previous_bytes = args.previous_report.read_bytes()
            require(hashlib.sha256(previous_bytes).hexdigest() == FIRST_REPORT_SHA256)
            previous = json.loads(previous_bytes, object_pairs_hook=unique_fields)
            original = validate_live(json.dumps(next(c["result"] for c in previous["checks"] if c["name"] == "live-run")).encode())
            require(not original["passed"] and original["cases"][0]["passed"] and original["cases"][1]["failure"] == "judgment")
            require(original["clientAttempts"] == original["clientResponses"] == 4)
            prior_attempts = original["clientAttempts"]; prior_responses = original["clientResponses"]
            report["preserved_first_report_sha256"] = FIRST_REPORT_SHA256
            report["prior_attempt_counts"] = {"attempts": prior_attempts, "responses": prior_responses}
        else:
            require(args.previous_report is None)
        snapshot, captured, snapshot_hash = read_snapshot(args.snapshot, repo)
        report["base_commit"] = snapshot["base_commit"]
        report["accepted_snapshot_report_sha256"] = snapshot_hash
        report["source_boundary"] = "accepted isolated replay snapshot plus only this separate live harness/checker; no in-flight App dependencies"
        for relative in [HARNESS, CHECKER, TESTS]: captured[relative] = (repo / relative).read_bytes()
        contract_lines = [line.strip() for line in captured[HARNESS].decode().splitlines() if any(token in line for token in
            ['var goal = "Briefly', 'if id == "currentPriority" { goal +=', 'learning.mutateProfile({ _ = try $0.add(text:',
             'learning.mutateMemory({ _ = try $0.add(kind:'])]
        require(hashlib.sha256("\n".join(contract_lines).encode()).hexdigest() == CASE_CONTRACT_SHA256)
        report["unchanged_original_goal_and_preferences_sha256"] = CASE_CONTRACT_SHA256
        for relative, data in captured.items():
            path = source / relative; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data)
            report["source_sha256"][relative] = hashlib.sha256(data).hexdigest()
        config = runpy.run_path(str(source / "scripts/check_profile_chat_app.py"))
        modules = config["MODULES"]
        run("publication-tests", ["python3", "-m", "unittest", "discover", "-s", str(source / "scripts"), "-p", Path(TESTS).name], 30)
        for name, dependencies in modules:
            paths = [str(source / p) for p in sorted(captured) if Path(p).parent == Path("Sources") / name]
            run(name + "-build", ["swiftc", "-swift-version", "5", "-parse-as-library", "-emit-module", "-emit-library", "-module-name", name,
                "-emit-module-path", str(out / (name + ".swiftmodule")), "-I", str(out), "-L", str(out), *paths,
                *["-l" + dependency for dependency in dependencies], "-o", str(out / ("lib" + name + ".dylib"))])
        binary = out / "live-replay"
        run("harness-parse", ["swiftc", "-frontend", "-parse", "-warnings-as-errors", str(source / HARNESS)])
        apps = [str(source / "Sources/App" / (name + ".swift")) for name in config["APP_SOURCES"]]
        run("harness-build", ["swiftc", "-swift-version", "5", "-parse-as-library", "-I", str(out), "-L", str(out),
            *["-l" + name for name, _ in modules], "-Xlinker", "-rpath", "-Xlinker", str(out), *apps, str(source / HARNESS), "-o", str(binary)])
        run("offline-preflight", [str(binary), "--self-check"], 30)
        relevant = ["Sources/App/BrowserSession.swift", HARNESS, CHECKER, TESTS]
        require(all((repo / p).read_bytes() == captured[p] for p in relevant))
        if args.live:
            if not all(private.values()): raise CheckFailure("missing_configuration")
            if not args.attempt_record: raise CheckFailure("attempt_record_required")
            if args.diagnostic_current_priority:
                # One explicitly authorized repeat, tied to the immutable first failure.
                with args.previous_report.with_suffix(".diagnostic-used").open("x") as handle:
                    handle.write(FIRST_REPORT_SHA256 + "\n")
            # Never overwrite an earlier attempt's evidence or silently rerun it.
            with args.attempt_record.open("x") as handle: json.dump({"attempts": 0, "responses": 0}, handle)
            private["WOOW_REPLAY_ATTEMPT_RECORD"] = str(args.attempt_record.resolve())
            private["WOOW_REPLAY_PRIOR_ATTEMPTS"] = str(prior_attempts)
            report["live_attempted"] = True; save()
            run("live-run", [str(binary), "--diagnostic-current-priority" if args.diagnostic_current_priority else "--live"], 540, live=True)
            report["status"] = "PASS"
        else:
            report["status"] = "PREFLIGHT_PASS_NOT_LIVE"
        report["frozen_browser_and_harness_still_current"] = all((repo / p).read_bytes() == captured[p] for p in relevant)
        if not report["frozen_browser_and_harness_still_current"]: raise CheckFailure("source_changed")
    except FileExistsError:
        report["status"] = "FAIL"; report["failure"] = "attempt_already_exists"
    except CheckFailure as error:
        report["status"] = "FAIL"; report["failure"] = str(error)
    except subprocess.TimeoutExpired:
        report["status"] = "FAIL"; report["failure"] = "process_deadline"
    except Exception:
        report["status"] = "FAIL"; report["failure"] = "local_preflight_failure"
    finally:
        if report["live_attempted"] and args.attempt_record:
            try:
                raw = args.attempt_record.read_bytes(); require(len(raw) <= 512)
                journal = json.loads(raw, object_pairs_hook=unique_fields)
                require(set(journal) == {"attempts", "responses"} and integer(journal["attempts"], 8) and integer(journal["responses"], journal["attempts"]))
                report["persisted_attempt_counts"] = journal
                require(journal["attempts"] + prior_attempts <= 8)
                report["cumulative_attempt_counts"] = {"attempts": journal["attempts"] + prior_attempts,
                                                        "responses": journal["responses"] + prior_responses}
                live_rows = [r for r in report["checks"] if r["name"] == "live-run"]
                if live_rows:
                    require(live_rows[0]["result"]["clientAttempts"] == journal["attempts"] and live_rows[0]["result"]["clientResponses"] == journal["responses"])
            except Exception:
                report["status"] = "FAIL"; report["failure"] = "attempt_evidence_invalid"
        if "relevant" in locals():
            report["frozen_browser_and_harness_still_current"] = all((repo / p).read_bytes() == captured[p] for p in relevant)
        save(); print("REPORT=" + str(out / "report.json"), flush=True)
    return 0 if report["status"] in ["PASS", "PREFLIGHT_PASS_NOT_LIVE"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
