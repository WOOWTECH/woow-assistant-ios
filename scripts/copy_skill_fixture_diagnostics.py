#!/usr/bin/env python3
"""Inventory only synthetic UUID PDFs recorded by the strictly gated DEBUG seeder.
No glob of Documents, raw PDFs/text, user paths or secrets enter the report.
Evidence collection never replaces the original xcodebuild/test result.
"""
import json
import math
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid

MARKER = "SKILL_PDF_FIXTURE_BASELINE "
LIMIT = 128 * 1024
STAT_FIELDS = {"bytes", "device", "inode", "modifiedSeconds", "modifiedNanoseconds", "sha256"}
STATUSES = {"valid", "directoryUnavailable", "missing", "openRejected", "statFailed",
            "unsafeFile", "oversized", "readFailed", "changedDuringRead", "invalidFixture"}


def checked(value):
    if not isinstance(value, dict) or set(value) != {"version", "namespace", "phase", "evidence"}:
        raise ValueError()
    if type(value["version"]) is not int or value["version"] != 1 or value["phase"] not in ("created", "existing"):
        raise ValueError()
    if not isinstance(value["namespace"], str) or str(uuid.UUID(value["namespace"])).upper() != value["namespace"]:
        raise ValueError()
    evidence = value["evidence"]
    if not isinstance(evidence, dict) or evidence.get("status") not in STATUSES:
        raise ValueError()
    expected = {"status", "sampledAt"} | (STAT_FIELDS if evidence["status"] == "valid" else set())
    if set(evidence) != expected or type(evidence["sampledAt"]) not in (float, int) or not math.isfinite(evidence["sampledAt"]):
        raise ValueError()
    if evidence["status"] == "valid":
        if any(type(evidence[key]) is not int for key in STAT_FIELDS - {"sha256"}):
            raise ValueError()
        if not 0 <= evidence["bytes"] <= LIMIT or not 0 <= evidence["inode"] < 2**64:
            raise ValueError()
        if not -(2**31) <= evidence["device"] < 2**31 or not 0 <= evidence["modifiedNanoseconds"] < 10**9:
            raise ValueError()
        if not isinstance(evidence["sha256"], str) or re.fullmatch(r"[0-9a-f]{64}", evidence["sha256"]) is None:
            raise ValueError()
    return value


def baselines_from_logs(directory):
    baselines = {}
    files = records = total = 0
    for path in sorted(directory.rglob("StandardOutputAndStandardError-io.woowtech.assistant.txt")):
        files += 1
        if files > 8 or path.is_symlink() or not path.is_file():
            raise ValueError()
        with path.open("rb") as stream:
            while True:
                line = stream.readline(65_537)
                if not line:
                    break
                total += len(line)
                if total > 256 * 1024 * 1024:
                    raise ValueError()
                text = line.decode("utf-8", errors="replace")
                if MARKER not in text:
                    continue
                payload = text.split(MARKER, 1)[1].strip()
                if len(payload) > 4096:
                    raise ValueError()
                value = checked(json.loads(payload))
                records += 1
                if records > 64:
                    raise ValueError()
                # Keep the first creation baseline, never replace it on re-entry.
                prior = baselines.get(value["namespace"])
                if prior is None or (prior["phase"] == "existing" and value["phase"] == "created"):
                    baselines[value["namespace"]] = value
                if len(baselines) > 16:
                    raise ValueError()
    return list(baselines.values())


def main():
    output = None
    failure_phase = "invalid-arguments"
    try:
        if len(sys.argv) != 4:
            raise ValueError()
        output = Path(sys.argv[3])
        output.parent.mkdir(parents=True, exist_ok=True)
        simulator = str(uuid.UUID(sys.argv[1]))
        failure_phase = "baselines-unavailable-or-rejected"
        baselines = baselines_from_logs(Path(sys.argv[2]))
        if not baselines:
            output.write_text(json.dumps({"version": 1, "observation": "unavailable", "reason": "no-debug-baselines"}) + "\n")
            print("PDF fixture evidence: no DEBUG baselines; no Documents files inspected")
            return 0
        failure_phase = "simulator-container-unavailable"
        result = subprocess.run(["xcrun", "simctl", "get_app_container", simulator, "io.woowtech.assistant", "data"],
                                capture_output=True, text=True, timeout=20, check=True)
        container = Path(result.stdout.strip())
        if not container.is_absolute() or not container.is_dir() or container.is_symlink():
            raise ValueError()
        repo = Path(__file__).resolve().parent.parent
        with tempfile.TemporaryDirectory(prefix="woow-pdf-inventory-") as work:
            work = Path(work)
            baseline_file = work / "baselines.json"
            baseline_file.write_text(json.dumps(baselines))
            executable = work / "inventory"
            failure_phase = "inventory-compile-failed"
            subprocess.run(["xcrun", "swiftc", "-DDEBUG", "-parse-as-library",
                            str(repo / "Sources/App/SkillExecutionUITestSupport.swift"),
                            str(repo / "scripts/SkillFixtureInventory.swift"), "-o", str(executable)],
                           capture_output=True, timeout=60, check=True)
            failure_phase = "inventory-execution-failed"
            subprocess.run([str(executable), str(container / "Documents"), str(baseline_file), str(output)],
                           capture_output=True, timeout=30, check=True)
        print(f"PDF fixture evidence: inspected {len(baselines)} exact synthetic UUID paths after tests")
    except (OSError, ValueError, TypeError, OverflowError, subprocess.SubprocessError):
        if output is not None:
            try:
                output.write_text(json.dumps({"version": 1, "observation": "unavailable", "reason": failure_phase}) + "\n")
            except OSError:
                pass
        print("PDF fixture evidence: unavailable or rejected; original test result preserved")
    return 0


if __name__ == "__main__":
    sys.exit(main())
