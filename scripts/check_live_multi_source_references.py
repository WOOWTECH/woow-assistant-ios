#!/usr/bin/env python3
"""Compile exact current production sources. --live explicitly uses real model quota.

Credentials arrive only via WOOW_MODEL_TEST_{BASE_URL,MODEL,API_KEY}; never argv,
reports, compiler environment or raw subprocess logs. Default is compile only.
Three real public WebKit/model cases share a 12-model-call quota. Each uses the
unchanged 180s runner deadline. One separately labeled forged-citation replay
uses immutable actual observations and a synthetic reply, with no HTTP call.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

from check_profile_chat_app import APP_SOURCES, MODULES

PRIVATE = ("WOOW_MODEL_TEST_BASE_URL", "WOOW_MODEL_TEST_MODEL", "WOOW_MODEL_TEST_API_KEY")
HARNESS = "scripts/LiveMultiSourceReferenceSmoke.swift"
ROOTS = ["https://www.iana.org/domains/reserved", "https://www.rfc-editor.org/rfc/rfc2606.txt"]
CASES = ["savedPreference", "currentOverride", "referenceIsNotEvidence"]
FAILURES = {"none", "configuration", "deadline", "modelBudget", "modelFailure", "inputBoundary",
            "sources", "incomplete", "preference", "goalOverride", "citation", "forgedCitationAccepted", "unknown"}
HTTP_FAILURES = {"invalidConfiguration", "redirectRejected", "httpStatus", "invalidResponse",
                 "incompleteResponse", "responseTooLarge", "consumerTooSlow", "timedOut", "transportFailure"}


class CheckFailure(Exception):
    """Only fixed codes reach output; never provider errors or arbitrary stdout."""


def unique_fields(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise CheckFailure("invalid_live_report")
        result[key] = value
    return result


def clean_environment(environment):
    return {k: v for k, v in environment.items() if k in
            {"PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "SDKROOT", "DEVELOPER_DIR"}}


def validate_live(raw):
    """Strict nested whitelist, including hashes/counters. Raw answers never survive."""
    def require(value):
        if not value:
            raise CheckFailure("invalid_live_report")

    def integer(value, maximum):
        return type(value) is int and 0 <= value <= maximum

    def sha(value):
        return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None

    require(len(raw) <= 65536)
    try:
        result = json.loads(raw, object_pairs_hook=unique_fields)
        require(set(result) == {"passed", "failure", "cases", "modelCalls", "forgedReplayRejected",
                               "forgedReplayModelCalls", "forgedReplayNetworkRequests", "milliseconds",
                               "priorModelCalls", "cumulativeModelCalls", "diagnosticOnly"})
        require(type(result["passed"]) is bool and result["failure"] in FAILURES)
        require(type(result["diagnosticOnly"]) is bool and integer(result["priorModelCalls"], 11))
        require(integer(result["cumulativeModelCalls"], 12)
                and result["cumulativeModelCalls"] == result["priorModelCalls"] + result["modelCalls"])
        if result["diagnosticOnly"]:
            require(integer(result["modelCalls"], 1) and len(result["cases"]) <= 1)
            require(not result["forgedReplayRejected"] and result["forgedReplayModelCalls"] == 0)
        require(integer(result["modelCalls"], 12) and integer(result["milliseconds"], 570000))
        require(type(result["forgedReplayRejected"]) is bool and integer(result["forgedReplayModelCalls"], 1))
        require(type(result["forgedReplayNetworkRequests"]) is int and result["forgedReplayNetworkRequests"] == 0)
        require(isinstance(result["cases"], list) and len(result["cases"]) <= 3)
        for index, case in enumerate(result["cases"]):
            require(set(case) == {"id", "passed", "failure", "modelCalls", "modelResponses", "inputBoundaryVerified",
                                  "prefixMatched", "citedOrigins", "findingCount", "privateCitationCount", "receipts", "citations", "milliseconds", "modelErrors"})
            require(case["id"] == CASES[index] and case["failure"] in FAILURES)
            require(all(type(case[k]) is bool for k in ["passed", "inputBoundaryVerified", "prefixMatched"]))
            require(integer(case["modelCalls"], 12) and integer(case["modelResponses"], case["modelCalls"]))
            require(isinstance(case["modelErrors"], list)
                    and len(case["modelErrors"]) <= case["modelCalls"] - case["modelResponses"])
            for error in case["modelErrors"]:
                require(set(error) == {"kind", "statusCode"} and error["kind"] in HTTP_FAILURES)
                require(type(error["statusCode"]) is int and
                        (error["statusCode"] == 0 or (error["kind"] == "httpStatus" and 100 <= error["statusCode"] <= 599)))
            require(integer(case["citedOrigins"], 2) and integer(case["findingCount"], 8)
                    and integer(case["privateCitationCount"], 24) and integer(case["milliseconds"], 570000))
            require(isinstance(case["receipts"], list) and len(case["receipts"]) <= 15)
            receipts = {}
            for row in case["receipts"]:
                require(set(row) == {"source", "page", "urlSHA256", "textSHA256", "capturedAt"})
                require(row["source"] in ["source-1", "source-2"] and integer(row["page"], 15) and row["page"] > 0)
                require(row["page"] not in receipts and sha(row["urlSHA256"]) and sha(row["textSHA256"]))
                require(type(row["capturedAt"]) in (float, int) and 0 < row["capturedAt"] < 253402300799)
                receipts[row["page"]] = row["source"]
            require(isinstance(case["citations"], list) and len(case["citations"]) <= 24)
            for row in case["citations"]:
                require(set(row) == {"source", "page", "quoteSHA256", "utf8Bytes", "exactObservedRange"})
                require(integer(row["page"], 15) and receipts.get(row["page"]) == row["source"])
                require(sha(row["quoteSHA256"]) and integer(row["utf8Bytes"], 2048) and row["utf8Bytes"] > 0)
                require(type(row["exactObservedRange"]) is bool)
            if case["passed"]:
                require(case["failure"] == "none" and case["inputBoundaryVerified"] and case["prefixMatched"])
                require(1 <= case["modelCalls"] == case["modelResponses"] and case["citedOrigins"] == 2)
                require(case["findingCount"] >= 1 and case["privateCitationCount"] == 0)
                require({c["source"] for c in case["citations"]} == {"source-1", "source-2"})
                require(all(c["exactObservedRange"] for c in case["citations"]))
            else:
                require(case["failure"] != "none" and index == len(result["cases"]) - 1)
        require(sum(c["modelCalls"] for c in result["cases"]) == result["modelCalls"])
        if result["passed"]:
            require(result["failure"] == "none" and len(result["cases"]) == (1 if result["diagnosticOnly"] else 3)
                    and all(c["passed"] for c in result["cases"]))
            if not result["diagnosticOnly"]:
                require(result["forgedReplayRejected"] and result["forgedReplayModelCalls"] == 1)
        else:
            require(result["failure"] != "none")
        return result
    except (ValueError, KeyError, TypeError, AttributeError, OverflowError):
        raise CheckFailure("invalid_live_report") from None


def prior_usage(path):
    """One immutable predecessor, not a list that could double-count a chain."""
    try:
        raw = path.read_bytes()
        if len(raw) > 512 * 1024:
            raise ValueError()
        report = json.loads(raw, object_pairs_hook=unique_fields)
        rows = [row for row in report["checks"] if row["name"] == "live-run"]
        if len(rows) != 1 or not report["live_attempted"]:
            raise ValueError()
        result = rows[0]["result"]
        count = result.get("cumulativeModelCalls", result["modelCalls"])
        if type(count) is not int or not 1 <= count < 12:
            raise ValueError()
        if "cumulativeModelCalls" in result:
            validate_live(json.dumps(result).encode())
        elif count != sum(c["modelCalls"] for c in result["cases"]):
            raise ValueError()
        return count, hashlib.sha256(raw).hexdigest()
    except (OSError, ValueError, KeyError, TypeError):
        raise CheckFailure("invalid_prior_budget_report") from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--diagnostic-one-call", action="store_true")
    parser.add_argument("--previous-report", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    out = Path(tempfile.mkdtemp(prefix="woow-live-multi-reference-"))
    source = out / "source"
    environment = clean_environment(os.environ)
    private = {k: os.environ.get(k, "") for k in PRIVATE}
    prior = 0
    report = {"schema_version": 1, "status": "INCOMPLETE", "checks": [], "source_sha256": {},
              "live_requested": args.live, "live_attempted": False, "approved_public_roots": ROOTS,
              "synthetic_references_only": True, "actual_webkit_executor": "MultiSourceResearchWebKitExecutor",
              "host_store_capture_exercised": False, "native_ios_execution": False,
              "raw_model_or_request_logs": False, "production_source_substitution": False,
              "maximum_total_model_calls": 12, "per_case_runner_deadline_seconds": 180,
              "process_deadline_seconds": 570, "forged_replay": "synthetic command over actual immutable page observations; no HTTP"}

    def save():
        data = json.dumps(report, indent=2, sort_keys=True) + "\n"
        (out / "report.json").write_text(data)
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True); args.output.write_text(data)

    def copy(relative):
        data = (repo / relative).read_bytes()
        target = source / relative; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(data)
        report["source_sha256"][relative] = hashlib.sha256(data).hexdigest()
        return str(target)

    def verify():
        expected = {p for p in report["source_sha256"] if p.startswith("Sources/Assistant")}
        current = {str(p.relative_to(repo)) for module, _ in MODULES for p in (repo / "Sources" / module).glob("*.swift")}
        if expected != current or not all(hashlib.sha256((repo / p).read_bytes()).hexdigest() == h
                                         for p, h in report["source_sha256"].items()):
            raise CheckFailure("source_changed")

    def run(name, command, live=False):
        started = time.monotonic()
        process = subprocess.run(command, env={**environment, **(private if live else {})},
                                 capture_output=True, timeout=570 if live else 180)
        row = {"name": name, "exit_code": process.returncode, "seconds": round(time.monotonic() - started, 3)}
        if live:
            row["result"] = validate_live(process.stdout) # stderr/raw stdout never written, even on failure.
            if (row["result"]["priorModelCalls"] != prior
                    or row["result"]["diagnosticOnly"] != args.diagnostic_one_call):
                raise CheckFailure("invalid_live_report")
        elif process.returncode:
            (out / (name + ".log")).write_bytes(process.stdout + process.stderr)
        elif name == "harness-build":
            own = [line for line in process.stderr.decode(errors="replace").splitlines()
                   if "warning:" in line and Path(HARNESS).name in line]
            row["harness_warnings"] = len(own)
            if own:
                (out / (name + ".log")).write_bytes(process.stderr)
                raise CheckFailure("harness_warning")
        report["checks"].append(row); save()
        print(json.dumps({k: row[k] for k in ["name", "exit_code", "seconds"]}), flush=True)
        if process.returncode or (live and not row["result"]["passed"]):
            raise CheckFailure("live_failed" if live else "compile_failed")

    print("REPORT=" + str(out / "report.json"), flush=True)
    try:
        if args.live:
            if not args.previous_report:
                raise CheckFailure("prior_budget_report_required")
            prior, previous_hash = prior_usage(args.previous_report)
            report["prior_model_calls"] = prior; report["previous_report_sha256"] = previous_hash
            report["maximum_new_model_calls"] = min(12 - prior, 1 if args.diagnostic_one_call else 12)
            private["WOOW_REFERENCE_PRIOR_CALLS"] = str(prior)
            private["WOOW_REFERENCE_DIAGNOSTIC_ONLY"] = "1" if args.diagnostic_one_call else "0"
        copy("scripts/check_live_multi_source_references.py"); copy("scripts/check_profile_chat_app.py")
        modules = {name: [copy(str(p.relative_to(repo))) for p in sorted((repo / "Sources" / name).glob("*.swift"))] for name, _ in MODULES}
        apps = [copy("Sources/App/" + name + ".swift") for name in APP_SOURCES]
        harness = copy(HARNESS)
        for name, dependencies in MODULES:
            run(name + "-build", ["swiftc", "-swift-version", "5", "-parse-as-library", "-emit-module", "-emit-library",
                "-module-name", name, "-emit-module-path", str(out / (name + ".swiftmodule")), "-I", str(out), "-L", str(out),
                *modules[name], *["-l" + d for d in dependencies], "-o", str(out / ("lib" + name + ".dylib"))])
        binary = out / "live-multi-reference"
        run("harness-parse", ["swiftc", "-frontend", "-parse", "-warnings-as-errors", harness])
        run("harness-build", ["swiftc", "-swift-version", "5", "-parse-as-library", "-I", str(out), "-L", str(out),
            *["-l" + name for name, _ in MODULES], "-Xlinker", "-rpath", "-Xlinker", str(out), *apps, harness, "-o", str(binary)])
        verify(); report["sources_still_current"] = True
        if args.live:
            if not all(private.values()):
                raise CheckFailure("missing_live_configuration")
            report["live_attempted"] = True; save()
            run("live-run", [str(binary)], live=True)
            verify(); report["status"] = "DIAGNOSTIC_COMPLETED" if args.diagnostic_one_call else "PASS"
        else:
            report["status"] = "COMPILED_NOT_EXECUTED"
    except CheckFailure as error:
        report["status"] = "FAIL"; report["failure"] = str(error)
    except subprocess.TimeoutExpired:
        report["status"] = "FAIL"; report["failure"] = "process_deadline"
    except Exception:
        report["status"] = "FAIL"; report["failure"] = "runner_failure"
    finally:
        report["sources_still_current"] = all(hashlib.sha256((repo / p).read_bytes()).hexdigest() == h for p, h in report["source_sha256"].items())
        save(); print("REPORT=" + str(out / "report.json"), flush=True)
    return 0 if report["status"] in {"PASS", "COMPILED_NOT_EXECUTED", "DIAGNOSTIC_COMPLETED"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
