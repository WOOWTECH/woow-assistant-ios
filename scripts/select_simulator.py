"""Select an available iPhone from `xcrun simctl list devices available -j`.

CI supplies a runtime matching its pinned Xcode. Local runs select the newest
available iOS runtime. An optional device name must match exactly; requested
filters never fall back to another runtime or device. No devices are created,
erased, or otherwise changed.
"""

import argparse
import json
import re
import sys


def select_device(payload, runtime=None, device_name=None):
    candidates = []
    for key, devices in payload.get("devices", {}).items():
        match = re.search(r"\.iOS-(\d+)-(\d+)(?:-(\d+))?$", key)
        if not match or (runtime is not None and not key.endswith("." + runtime)):
            continue
        version = tuple(int(n or 0) for n in match.groups())
        if version[0] < 17:
            continue
        for device in devices:
            name = device.get("name", "")
            if (device.get("isAvailable") and name.startswith("iPhone")
                    and (device_name is None or name == device_name)):
                candidates.append((version, name, device["udid"]))
    if not candidates:
        filters = []
        if runtime is not None:
            filters.append(f"runtime={runtime!r}")
        if device_name is not None:
            filters.append(f"device={device_name!r}")
        detail = " matching " + ", ".join(filters) if filters else ""
        raise ValueError("No available iPhone with iOS 17+" + detail)
    return sorted(candidates, reverse=True)[0][2]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", help="Runtime suffix, e.g. iOS-18-5")
    parser.add_argument("--device", help="Exact device name, e.g. iPhone SE (3rd generation)")
    args = parser.parse_args()
    try:
        print(select_device(json.load(sys.stdin), args.runtime, args.device))
    except (ValueError, KeyError, TypeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
