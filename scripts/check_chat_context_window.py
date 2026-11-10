#!/usr/bin/env python3
"""Compile and exercise the real pure Swift window using CLT, without XCTest."""
from pathlib import Path
import subprocess
import tempfile


def main():
    repo = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="woow-chat-window-") as temporary:
        binary = Path(temporary) / "checks"
        subprocess.run([
            "swiftc", "-warnings-as-errors", "-D", "CHAT_CONTEXT_WINDOW_STANDALONE",
            "-parse-as-library",
            str(repo / "Sources/AssistantModels/ModelConfiguration.swift"),
            str(repo / "Sources/AssistantModels/ChatContextWindow.swift"),
            str(repo / "Tests/AssistantModelsTests/ChatContextWindowTests.swift"),
            "-o", str(binary),
        ], check=True, timeout=120, cwd=repo)
        subprocess.run([str(binary)], check=True, timeout=30, cwd=repo)


if __name__ == "__main__":
    try:
        main()
    except subprocess.TimeoutExpired:
        raise SystemExit("CHAT_CONTEXT_WINDOW_CHECK_TIMEOUT")
    except subprocess.CalledProcessError:
        raise SystemExit("CHAT_CONTEXT_WINDOW_CHECK_FAILED")
