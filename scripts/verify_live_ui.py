#!/usr/bin/env python3
"""Verify private Live UI completion using source inventory and xcresult counts.

--selector accepts WoowAssistantUITests/LiveClass[/testMethod], once per
non-overlapping selection. This verifies the summary against the selection;
it does not publish the summary, failure text, paths, or process environment.
Exit 0 means PASSED; every rejected invocation/result exits 1 with a fixed code.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from release_ios17 import ui_inventory

COUNT_KEYS = ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures")
FAILURE_KEYS = ("failedTests", "skippedTests", "expectedFailures")
MAX_COUNT = 100_000
MAX_SUMMARY_BYTES = 2 * 1024 * 1024
CHILD_ENV_KEYS = ("PATH", "DEVELOPER_DIR", "TMPDIR", "TMP", "TEMP")
ROOT = Path(__file__).resolve().parents[1]


class VerificationError(Exception):
    def __init__(self, code, counts=None):
        super().__init__(code)
        self.code = code
        self.counts = counts or {}


class FixedErrorParser(argparse.ArgumentParser):
    def error(self, message):
        # argparse normally echoes unrecognized arguments/values into stderr.
        raise VerificationError("INVALID_ARGUMENTS")


def expected_tests(root, selectors):
    if not selectors or len(selectors) > 128:
        raise VerificationError("INVALID_SELECTOR")
    try:
        catalog = ui_inventory(root)
        available = catalog["live_tests_excluded"]
        if (not available or len(available) > MAX_COUNT
                or len(available) != len(set(available))):
            raise ValueError("invalid source inventory")
    except Exception:
        raise VerificationError("INVALID_INVENTORY") from None
    selected = set()
    for selector in selectors:
        if (not isinstance(selector, str) or len(selector) > 256
                or not re.fullmatch(r"WoowAssistantUITests/[A-Za-z_][A-Za-z0-9_]*(?:/test[A-Za-z0-9_]+)?", selector)):
            raise VerificationError("INVALID_SELECTOR")
        matches = {test for test in available if test == selector or test.startswith(selector + "/")}
        if not matches or selected.intersection(matches):
            raise VerificationError("INVALID_SELECTOR")
        selected.update(matches)
    return sorted(selected)


def child_environment(environment):
    # No model/MCP keys, URLs, SIMCTL_CHILD_*, DYLD_*, HOME, or GitHub tokens.
    result = {key: environment[key] for key in CHILD_ENV_KEYS if key in environment}
    result.setdefault("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
    return result


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def invalid_constant(value):
    raise ValueError("non-JSON numeric constant")


def read_summary(result, environment):
    if not result.is_dir() or result.suffix != ".xcresult":
        raise VerificationError("RESULT_MISSING")
    try:
        completed = subprocess.run(
            ["/usr/bin/xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result.resolve())],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=120, check=False, env=child_environment(environment))
    except subprocess.TimeoutExpired:
        raise VerificationError("TOOL_TIMEOUT") from None
    except OSError:
        raise VerificationError("TOOL_UNAVAILABLE") from None
    if completed.returncode != 0:
        raise VerificationError("TOOL_FAILED")
    if len(completed.stdout) > MAX_SUMMARY_BYTES:
        raise VerificationError("SUMMARY_TOO_LARGE")
    try:
        return json.loads(completed.stdout.decode("utf-8"), object_pairs_hook=unique_object,
                          parse_constant=invalid_constant)
    except (ValueError, UnicodeError, RecursionError):
        raise VerificationError("INVALID_SUMMARY") from None


def checked_counts(value, keys):
    if not isinstance(value, dict):
        raise VerificationError("INVALID_SUMMARY")
    counts = {key: value.get(key) for key in keys}
    if not all(type(v) is int and 0 <= v <= MAX_COUNT for v in counts.values()):
        raise VerificationError("INVALID_SUMMARY")
    return counts


def verify_summary(summary, expected):
    counts = checked_counts(summary, COUNT_KEYS)
    if summary.get("result") != "Passed":
        raise VerificationError("NOT_PASSED", counts)
    failures = summary.get("testFailures", [])
    if not isinstance(failures, list):
        raise VerificationError("INVALID_SUMMARY", counts)
    if failures or any(counts[key] != 0 for key in FAILURE_KEYS):
        raise VerificationError("FAILURES_PRESENT", counts)
    if expected <= 0 or counts["totalTestCount"] != expected or counts["passedTests"] != expected:
        raise VerificationError("COUNT_MISMATCH", counts)
    # Also reject contradictory per-destination failure metadata when present.
    # Repeated execution on several destinations must not hide behind one total.
    if "devicesAndConfigurations" in summary:
        devices = summary["devicesAndConfigurations"]
        if not isinstance(devices, list) or not devices:
            raise VerificationError("INVALID_SUMMARY", counts)
        passed = 0
        for device in devices:
            local = checked_counts(device, ("passedTests",) + FAILURE_KEYS)
            if any(local[key] != 0 for key in FAILURE_KEYS):
                raise VerificationError("FAILURES_PRESENT", counts)
            passed += local["passedTests"]
        if passed != expected:
            raise VerificationError("COUNT_MISMATCH", counts)
    return counts


def verify(result, selectors, root=ROOT, environment=None):
    expected = 0
    try:
        expected = len(expected_tests(root, selectors))
        summary = read_summary(result, os.environ if environment is None else environment)
        counts = verify_summary(summary, expected)
        return {"code": "PASSED", "expectedTests": expected, **counts}
    except VerificationError as error:
        return {"code": error.code, "expectedTests": expected, **error.counts}
    except Exception:
        # Never echo a parser, filesystem, inventory, or tool exception payload.
        return {"code": "VERIFICATION_ERROR", "expectedTests": expected}


def main(argv=None):
    parser = FixedErrorParser(prog="verify_live_ui.py", description=__doc__, allow_abbrev=False)
    parser.add_argument("--result", type=Path, required=True)
    parser.add_argument("--selector", action="append", required=True)
    try:
        args = parser.parse_args(argv)
        result = verify(args.result, args.selector)
    except VerificationError as error:
        result = {"code": error.code, "expectedTests": 0}
    except KeyboardInterrupt:
        result = {"code": "INTERRUPTED", "expectedTests": 0}
    print(json.dumps(result, sort_keys=True))
    return 0 if result["code"] == "PASSED" else 1


if __name__ == "__main__":
    sys.exit(main())
