#!/usr/bin/env python3
"""Compare an Android checkout with the reviewed UI reference snapshot."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--android-repo", type=Path, required=True,
                        help="Local checkout of WOOWTECH/woowtech_mika_smart_app")
    parser.add_argument("--baseline", type=Path,
                        default=Path(__file__).resolve().parents[1] / "docs/android-ui-reference.json")
    args = parser.parse_args()
    try:
        baseline = json.loads(args.baseline.read_text(encoding="utf-8"))
        root = args.android_repo.resolve(strict=True)
        if not root.is_dir() or not isinstance(baseline.get("files"), dict):
            raise ValueError("Invalid checkout or reference manifest")
        changes = []
        for name, expected in sorted(baseline["files"].items()):
            path = (root / name).resolve()
            if not path.is_relative_to(root):
                raise ValueError(f"Reference path leaves checkout: {name}")
            if not path.is_file():
                changes.append({"path": name, "status": "missing"})
                continue
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
            if actual != expected:
                changes.append({"path": name, "status": "changed", "sha256": actual})
        git = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"],
                             capture_output=True, text=True, check=False)
        result = {"reference_repository": baseline["repository"],
                  "reference_commit": baseline["commit"],
                  "checkout_commit": git.stdout.strip() if git.returncode == 0 else None,
                  "checked_files": len(baseline["files"]), "changes": changes}
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 1 if changes else 0
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
        print(f"Reference check failed: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
