"""Select an available iPhone from `xcrun simctl list devices available -j`.

CI supplies a runtime matching its pinned Xcode. Local runs select the newest
available iOS runtime. No devices are created, erased, or otherwise changed.
"""

import argparse
import json
import re
import sys


def select_device(payload, runtime=None):
    candidates = []
    for key, devices in payload.get("devices", {}).items():
        match = re.search(r"\.iOS-(\d+)-(\d+)(?:-(\d+))?$", key)
        if not match or (runtime and not key.endswith("." + runtime)):
            continue
        version = tuple(int(n or 0) for n in match.groups())
        if version[0] < 17:
            continue
        for device in devices:
            if device.get("isAvailable") and device.get("name", "").startswith("iPhone"):
                candidates.append((version, device.get("name", ""), device["udid"]))
    if not candidates:
        raise ValueError("No available iPhone with iOS 17+ matching the requested runtime")
    return sorted(candidates, reverse=True)[0][2]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", help="Runtime suffix, e.g. iOS-18-5")
    args = parser.parse_args()
    try:
        print(select_device(json.load(sys.stdin), args.runtime))
    except (ValueError, KeyError, TypeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
