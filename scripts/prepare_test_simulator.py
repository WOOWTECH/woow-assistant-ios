#!/usr/bin/env python3
"""Select the existing CI iPhone, or create one disposable, identical-model peer.

No runtime installation, reset, boot retry, test retry, or all-device mutation.
The workflow boots the returned UUID and collects evidence before cleanup.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import sys
import uuid

from select_simulator import select_device


OWNER = "woow-ci-test-simulator-v1"
MAX_STATE_BYTES = 16384


def timestamp():
    return datetime.now(timezone.utc).isoformat()


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(
            r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", value):
        raise ValueError("Invalid simulator UUID")
    return str(uuid.UUID(value)).upper()


def command(*args):
    try:
        result = subprocess.run(["xcrun", "simctl", *args], check=True,
                                capture_output=True, timeout=60)
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        # Do not include arbitrary simctl stderr, host paths, or environments.
        raise ValueError("simctl " + args[0] + " failed or exceeded 60 seconds") from None
    return result.stdout.decode("utf-8").strip()


def devices(payload):
    return [(runtime, item) for runtime, items in payload["devices"].items()
            for item in items]


def selection(device_list, runtime_list, type_list, runtime, device):
    selected = identifier(select_device(device_list, runtime, device))
    matches = [(key, item) for key, item in devices(device_list)
               if identifier(item["udid"]) == selected]
    if len(matches) != 1:
        raise ValueError("Expected exactly one selected device record")
    runtime_id, item = matches[0]
    if runtime_id != "com.apple.CoreSimulator.SimRuntime." + runtime:
        raise ValueError("Selected runtime identifier differs from requested runtime")
    runtimes = [entry for entry in runtime_list["runtimes"]
                if entry.get("identifier") == runtime_id and entry.get("isAvailable")]
    if len(runtimes) != 1:
        raise ValueError("Expected exactly one installed, available runtime")
    type_id = item.get("deviceTypeIdentifier")
    types = [entry for entry in type_list["devicetypes"]
             if entry.get("identifier") == type_id and entry.get("name") == device]
    if (not isinstance(type_id, str)
            or not type_id.startswith("com.apple.CoreSimulator.SimDeviceType.")
            or len(types) != 1):
        raise ValueError("Selected device type must match installed device metadata exactly")
    return {
        "source_simulator_id": selected,
        "source_simulator_state": item.get("state", "unknown"),
        "device_name": device,
        "device_type_identifier": type_id,
        "runtime_identifier": runtime_id,
        "runtime_version": runtimes[0]["version"],
        "runtime_build": runtimes[0]["buildversion"],
    }


def save(path, report, exclusive=False):
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if len(encoded.encode()) > MAX_STATE_BYTES or path.is_symlink():
        raise ValueError("Invalid simulator ownership record")
    if exclusive:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("x") as output:
            output.write(encoded)
    else:
        temporary = path.with_name(path.name + ".tmp")
        with temporary.open("x") as output:
            output.write(encoded)
        temporary.replace(path)


def prepare(path, runtime, device, fresh=False):
    if path.exists() or path.is_symlink():
        raise ValueError("Refusing to reuse simulator ownership record")
    inventory = json.loads(command("list", "devices", "--json"))
    report = selection(inventory, json.loads(command("list", "runtimes", "--json")),
                       json.loads(command("list", "devicetypes", "--json")), runtime, device)
    report.update(owner=OWNER, mode="fresh" if fresh else "existing",
                  selected_at=timestamp(), simulator_id=None, creation_attempted=False)
    if not fresh:
        report.update(simulator_id=report["source_simulator_id"], phase="selected_existing")
        save(path, report, exclusive=True)
        return report["simulator_id"]

    name = "Woow-CI-" + uuid.uuid4().hex
    if any(item.get("name") == name for _, item in devices(inventory)):
        raise ValueError("Disposable simulator name already exists")
    report.update(created_name=name, creation_attempted=True, phase="creating")
    # Checkpoint before create: if its response is lost, cleanup can identify
    # exactly this unique name plus runtime/type, never a pre-existing device.
    save(path, report, exclusive=True)
    try:
        created = identifier(command("create", name, report["device_type_identifier"],
                                     report["runtime_identifier"]))
        if any(identifier(item["udid"]) == created for _, item in devices(inventory)):
            raise ValueError("Create returned a pre-existing simulator UUID")
        report.update(simulator_id=created, phase="created", created_at=timestamp())
        save(path, report)
        observed = [(key, item) for key, item in devices(
            json.loads(command("list", "devices", "--json")))
            if identifier(item["udid"]) == created or item.get("name") == name]
        if (len(observed) != 1 or observed[0][0] != report["runtime_identifier"]
                or identifier(observed[0][1]["udid"]) != created
                or observed[0][1].get("name") != name
                or observed[0][1].get("deviceTypeIdentifier") != report["device_type_identifier"]
                or not observed[0][1].get("isAvailable")):
            raise ValueError("Created simulator does not match the selected runtime/device type")
        report.update(phase="ready_to_boot", identity_verified_at=timestamp())
        save(path, report)
        return created
    except (ValueError, OSError):
        report["phase"] = "create_failed"
        save(path, report)
        raise


def cleanup(path):
    if path.is_symlink():
        raise ValueError("Refusing linked ownership record")
    if not path.exists():
        return "no ownership record; no device changed"
    if not path.is_file() or path.stat().st_size > MAX_STATE_BYTES:
        raise ValueError("Invalid ownership record size or type")
    report = json.loads(path.read_text())
    if report.get("owner") != OWNER or report.get("mode") not in ("existing", "fresh"):
        raise ValueError("Unrecognized simulator owner or mode")
    source = identifier(report["source_simulator_id"])
    if report["mode"] == "existing":
        if identifier(report["simulator_id"]) != source or report.get("creation_attempted") is not False:
            raise ValueError("Invalid existing-device record")
        report.update(cleanup="not_owned_no_device_changed", cleanup_at=timestamp())
        save(path, report)
        return report["cleanup"]
    if (report.get("creation_attempted") is not True
            or not re.fullmatch(r"Woow-CI-[0-9a-f]{32}", report.get("created_name", ""))
            or not re.fullmatch(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-\d+-\d+(?:-\d+)?",
                                report.get("runtime_identifier", ""))
            or not report.get("device_type_identifier", "").startswith(
                "com.apple.CoreSimulator.SimDeviceType.")):
        raise ValueError("Invalid disposable simulator ownership")
    if report.get("cleanup") == "deleted":
        return "already deleted; no device changed"
    if report.get("delete_attempted"):
        raise ValueError("Delete already attempted; refusing automatic retry")
    created = identifier(report["simulator_id"]) if report.get("simulator_id") else None
    if created == source:
        raise ValueError("Refusing to mutate source simulator")
    inventory = devices(json.loads(command("list", "devices", "--json")))
    matches = [(key, item) for key, item in inventory
               if item.get("name") == report["created_name"]
               or (created and identifier(item["udid"]) == created)]
    if not matches:
        report.update(cleanup="owned_device_not_present", cleanup_at=timestamp())
        save(path, report)
        return report["cleanup"]
    if len(matches) != 1:
        raise ValueError("Ambiguous disposable simulator identity; no device changed")
    runtime_id, item = matches[0]
    observed = identifier(item["udid"])
    if (item.get("name") != report["created_name"] or observed == source
            or (created and observed != created) or runtime_id != report["runtime_identifier"]
            or item.get("deviceTypeIdentifier") != report["device_type_identifier"]):
        raise ValueError("Disposable simulator identity changed; no device changed")
    report.update(simulator_id=observed, delete_attempted=True, cleanup="deleting")
    save(path, report)
    try:
        try:
            command("shutdown", observed)
            report["shutdown_succeeded"] = True
        except ValueError:
            # An already-shutdown device can still be deleted by its exact UUID.
            report["shutdown_succeeded"] = False
        command("delete", observed)
        report["cleanup"] = "deleted"
    except ValueError:
        report["cleanup"] = "delete_failed"
        raise
    finally:
        report["cleanup_at"] = timestamp()
        save(path, report)
    return report["cleanup"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    start = commands.add_parser("prepare")
    start.add_argument("--runtime", required=True)
    start.add_argument("--device", required=True)
    start.add_argument("--fresh", action="store_true", default=False)
    start.add_argument("--state", type=Path, required=True)
    stop = commands.add_parser("cleanup")
    stop.add_argument("--state", type=Path, required=True)
    args = parser.parse_args()
    try:
        print(prepare(args.state, args.runtime, args.device, args.fresh)
              if args.action == "prepare" else cleanup(args.state))
    except (ValueError, KeyError, TypeError, OSError):
        # Detailed disposition stays in the bounded, synthetic ownership record.
        print("Simulator setup/cleanup failed; inspect test-simulator.json", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
