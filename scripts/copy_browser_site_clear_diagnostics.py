#!/usr/bin/env python3
"""Copy only the synthetic login fixture's bounded, value-free diagnostic JSON.
Run after UI tests and before uninstall/erasing the selected simulator.
Missing evidence never overrides the primary xcodebuild/test failure.
"""
import json
from pathlib import Path
import subprocess
import sys
import uuid

LIMIT = 16_384
FIELDS = {
    "begin": {"records", "sessions", "persistent"},
    "pageBegin": {"index"},
    "pageFinished": {"index", "stopped"},
    "pagesDiscarded": {"ready"},
    "sessionsReplaced": {"ready"},
    "recordsSelected": {"records", "types"},
    "removeNotNeeded": set(),
    "removeRequested": set(),
    "removeCompleted": set(),
    "fixtureCookies": {"remaining"},
    "recordsRefreshed": {"allRecords", "selectedRecords", "selectedCookieRecords",
                         "selectedMemoryCacheRecords", "selectedDiskCacheRecords", "selectedOtherDataTypes"},
}

def checked(raw):
    if len(raw) > LIMIT:
        raise ValueError()
    events = json.loads(raw)
    if not isinstance(events, list) or not 1 <= len(events) <= 64:
        raise ValueError()
    for event in events:
        if not isinstance(event, dict):
            raise ValueError()
        phase = event.get("phase")
        if not isinstance(phase, str) or phase not in FIELDS:
            raise ValueError()
        if set(event) != FIELDS[phase] | {"phase", "elapsedMs"}:
            raise ValueError()
        for key, value in event.items():
            if key != "phase" and (not isinstance(value, str) or not value.isascii()
                                   or not value.isdecimal() or len(value) > 12):
                raise ValueError()
    return json.dumps(events, ensure_ascii=True, sort_keys=True, indent=2).encode("ascii")

def main():
    try:
        if len(sys.argv) != 3:
            raise ValueError()
        simulator = str(uuid.UUID(sys.argv[1]))
        destination = Path(sys.argv[2])
        result = subprocess.run(["xcrun", "simctl", "get_app_container", simulator,
                                 "io.woowtech.assistant", "data"],
                                capture_output=True, text=True, timeout=20, check=True)
        container = Path(result.stdout.strip())
        if not container.is_absolute():
            raise ValueError()
        source = container / "Library/Caches/BrowserWebsiteRemovalDiagnostics.json"
        if source.is_symlink():
            raise ValueError()
        with source.open("rb") as stream:
            evidence = checked(stream.read(LIMIT + 1))
        if len(evidence) > LIMIT:
            raise ValueError()
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(evidence)
        print("Browser site-clear diagnostics: captured validated fixture phases")
    except (OSError, ValueError, TypeError, subprocess.SubprocessError):
        print("Browser site-clear diagnostics: unavailable or rejected; preserve primary test result")
    return 0

if __name__ == "__main__":
    sys.exit(main())
