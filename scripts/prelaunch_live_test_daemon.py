#!/usr/bin/env python3
"""One opt-in daemon prelaunch for the owned private-live iOS 17.0.1 device.

Reuses release_ios17's single attempt and shared 120-second budget. Only
fixed diagnostic metadata is printed. Process liveness is not an XCTest
handshake, and a failed or interrupted attempt cannot be repeated.
"""
import argparse
import json
from pathlib import Path
import re
import sys
import uuid

import prepare_live_simulator as live
from release_ios import ReleaseError


def prelaunch(output):
    path = output / live.STATE
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 8192:
        raise ReleaseError("Private Live prelaunch state is missing or invalid; no command executed.")
    report = json.loads(path.read_text())
    if not isinstance(report, dict):
        raise ReleaseError("Private Live prelaunch state is invalid; no command executed.")
    runtime = report.get("selected_runtime")
    if (report.get("owner") != live.OWNER or report.get("requested_runtime") != "17.0.1"
            or not isinstance(runtime, dict) or runtime.get("version") != "17.0.1"
            or runtime.get("identifier") not in live.RUNTIME_IDS["17.0.1"]
            or report.get("phase") != "ready" or report.get("boot_succeeded") is not True
            or report.get("cleanup_attempted") or report.get("simulator_deleted")):
        raise ReleaseError("Private Live prelaunch requires this run's ready exact iOS 17.0.1 simulator; no command executed.")
    simulator = report.get("simulator_id")
    try:
        valid_id = str(uuid.UUID(simulator)).upper() == simulator
    except (ValueError, TypeError, AttributeError):
        valid_id = False
    name = report.get("device_name")
    if not valid_id or not isinstance(name, str) or not re.fullmatch(r"Woow-Live-[0-9a-f]{32}", name):
        raise ReleaseError("Private Live prelaunch device ownership is invalid; no command executed.")
    if "test_daemon_prelaunch" in report:
        raise ReleaseError("Private Live daemon prelaunch was already requested; no retry executed.")

    # Persist the attempt fence before touching launchd, including when this
    # process is interrupted before the shared helper returns.
    report["test_daemon_prelaunch"] = {"status": "requested", "attempts": 0,
                                       "budget_seconds": 120, "handshake_verified": False}
    live.save(output, report)
    try:
        live.ios17.prelaunch_test_daemon(simulator, report)
    finally:
        live.save(output, report)
        diagnostic = report["test_daemon_prelaunch"]
        print(json.dumps({key: diagnostic[key] for key in
                          ("status", "attempts", "budget_seconds", "elapsed_seconds",
                           "process_alive", "handshake_verified") if key in diagnostic}, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("build/live-simulator"))
    args = parser.parse_args()
    try:
        prelaunch(args.output)
    except ReleaseError as error:
        print(str(error), file=sys.stderr)
        return 1
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        print("Private Live daemon prelaunch state could not be read or saved; no retry executed.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
