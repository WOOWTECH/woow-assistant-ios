#!/usr/bin/env python3
"""Run actual HTTP/App learning checks against a verified local compile snapshot.

First run check_profile_chat_app.py --typecheck-only. Set WOOW_MODEL_TEST_BASE_URL,
WOOW_MODEL_TEST_MODEL and WOOW_MODEL_TEST_API_KEY in the process environment.
This consumes model quota; it does not automate iOS UI or use personal Keychain.
"""
import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
from check_profile_chat_app import APP_SOURCES, MODULES


PRIVATE_FIELDS = ("WOOW_MODEL_TEST_BASE_URL", "WOOW_MODEL_TEST_MODEL", "WOOW_MODEL_TEST_API_KEY")
MCP_PRIVATE_FIELD = "WOOW_HA_MCP_TEST_URL"
HARNESSES = {"ordinary": "LiveLearningToolAppSmoke.swift", "mcp": "LiveMCPLearningAppSmoke.swift"}
VIEWS = ("ContentView", "UserProfileToolReviewView", "MemoryToolReviewView")
REQUIRED_CHECKS = {name + "-build" for name, _ in MODULES} | {
    config + suffix for config in ("Debug", "Release") for suffix in ("-typecheck", "-iOS-syntax")}
SNAPSHOT_ERROR = "Compile snapshot is incomplete or stale; regenerate before live testing."


def unique_fields(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate report field")
        result[key] = value
    return result


def snapshot_file(root, relative):
    path = (root / relative).resolve()
    path.relative_to(root)  # A copied source or report cannot escape its snapshot.
    return path.read_bytes()


def validate_snapshot(root, repo):
    """Return captured, verified bytes; never compile unchecked paths later."""
    try:
        root, repo = root.resolve(), repo.resolve()
        raw = snapshot_file(root, "report.json")
        if len(raw) > 256 * 1024:
            raise ValueError("Report too large")
        report = json.loads(raw, object_pairs_hook=unique_fields)
        if not isinstance(report, dict) or type(report.get("schema_version")) is not int or report["schema_version"] != 1:
            raise ValueError("Invalid report schema")
        checks = report.get("checks")
        if not isinstance(checks, list):
            raise ValueError("Missing checks")
        names = set()
        for check in checks:
            if (not isinstance(check, dict) or not isinstance(check.get("name"), str)
                    or check["name"] in names or type(check.get("exit_code")) is not int or check["exit_code"] != 0):
                raise ValueError("Invalid or unsuccessful check")
            names.add(check["name"])
        if not REQUIRED_CHECKS.issubset(names):
            raise ValueError("Required checks missing")

        required_sources = {"scripts/check_profile_chat_app.py"}
        for name, _ in MODULES:
            module_sources = {str(p.relative_to(repo)) for p in (repo / "Sources" / name).glob("*.swift")}
            if not module_sources:
                raise ValueError("Module sources missing")
            required_sources.update(module_sources)
        required_sources.update("Sources/App/" + name + ".swift" for name in (*APP_SOURCES, *VIEWS))
        hashes = report.get("source_sha256")
        if (not isinstance(hashes, dict) or not required_sources.issubset(hashes)
                or not set(hashes).issubset(required_sources | {"scripts/CheckProfileChatApp.swift"})):
            raise ValueError("Incomplete or unexpected source inventory")
        captured = {}
        for path, expected in hashes.items():
            if (not isinstance(expected, str) or len(expected) != 64
                    or any(c not in "0123456789abcdef" for c in expected)):
                raise ValueError("Invalid source digest")
            data = snapshot_file(root, "source/" + path)
            if (hashlib.sha256(data).hexdigest() != expected
                    or hashlib.sha256((repo / path).read_bytes()).hexdigest() != expected):
                raise ValueError("Source digest mismatch")
            captured[path] = data
        return dict(hashes), captured
    except (OSError, ValueError, TypeError, KeyError):
        raise SystemExit(SNAPSHOT_ERROR) from None


def run(snapshot, output, repo, harness="ordinary"):
    root, repo = snapshot.resolve(), repo.resolve()
    if harness not in HARNESSES:
        raise SystemExit("Unknown live App harness; no request sent.")
    required = PRIVATE_FIELDS + ((MCP_PRIVATE_FIELD,) if harness == "mcp" else ())
    if any(not os.environ.get(k) for k in required):
        raise SystemExit("Missing model test environment fields; no request sent.")
    hashes, captured = validate_snapshot(root, repo)
    harness_path = "scripts/" + HARNESSES[harness]
    harness = (repo / harness_path).read_bytes()
    hashes[harness_path] = hashlib.sha256(harness).hexdigest()
    hashes["scripts/run_live_learning_app.py"] = hashlib.sha256((repo / "scripts/run_live_learning_app.py").read_bytes()).hexdigest()
    build_environment = {k: v for k, v in os.environ.items() if k not in (*PRIVATE_FIELDS, MCP_PRIVATE_FIELD)}
    # Old preflight reports contain no binary hashes. Rebuild from the captured
    # verified bytes, instead of trusting possibly stale snapshot dylibs/modules.
    # Compilation shares one 120s budget; no private model fields reach swiftc.
    with tempfile.TemporaryDirectory(prefix="woow-live-learning-build-") as folder:
        build_root = pathlib.Path(folder)
        for path, data in captured.items():
            target = build_root / "source" / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        copied = build_root / "LiveLearningToolAppSmoke.swift"
        copied.write_bytes(harness)
        binary = build_root / "live-learning-app-smoke"
        deadline = time.monotonic() + 120

        def compile_sources(command):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise SystemExit("Live App compile budget exhausted; no request sent.")
            result = subprocess.run(command, env=build_environment, capture_output=True, text=True, timeout=remaining)
            if result.returncode:
                raise SystemExit("Live App check did not compile; no request sent.")

        for name, deps in MODULES:
            sources = [str(build_root / "source" / p) for p in sorted(captured)
                       if pathlib.PurePosixPath(p).parent == pathlib.PurePosixPath("Sources") / name]
            compile_sources(["swiftc", "-swift-version", "5", "-parse-as-library", "-emit-module", "-emit-library",
                "-module-name", name, "-emit-module-path", str(build_root / (name + ".swiftmodule")),
                "-I", str(build_root), "-L", str(build_root), *sources, *["-l" + d for d in deps],
                "-o", str(build_root / ("lib" + name + ".dylib"))])
        apps = [str(build_root / "source/Sources/App" / (name + ".swift")) for name in APP_SOURCES]
        compile_sources(["swiftc", "-swift-version", "5", "-DDEBUG", "-parse-as-library", "-I", str(build_root), "-L", str(build_root),
            *["-l" + name for name, _ in MODULES], "-Xlinker", "-rpath", "-Xlinker", str(build_root),
            *apps, str(copied), "-o", str(binary)])
        process = subprocess.run([str(binary)], capture_output=True, text=True, timeout=450)
    if process.returncode:
        raise SystemExit("Live App check process failed; raw output was not printed.")
    result = json.loads(process.stdout)
    result["source_sha256"] = hashes
    result["build_provenance"] = "recompiled_from_verified_snapshot_bytes"
    result["sources_still_current"] = all(
        hashlib.sha256((repo / p).read_bytes()).hexdigest() == h for p, h in hashes.items())
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k != "source_sha256"}, sort_keys=True))
    return 0 if result.get("passed") is True and result["sources_still_current"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--harness", choices=sorted(HARNESSES), default="ordinary")
    args = parser.parse_args()
    try:
        return run(args.snapshot, args.output, pathlib.Path(__file__).resolve().parent.parent, args.harness)
    except (OSError, ValueError, TypeError, KeyError, subprocess.TimeoutExpired):
        raise SystemExit("Live App check could not complete; private process output was not printed.") from None


if __name__ == "__main__":
    sys.exit(main())
