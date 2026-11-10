#!/usr/bin/env python3
"""Run actual core XCTest bodies + macOS WebKit in a captured source snapshot.

Default: synthetic/local-only assertions, with a loopback resource server.
--live: ONE explicit DuckDuckGo HTML search using the production adapter. No
fallback, credentials, model service or remote deployment. A failure remains a
failure. Public query/DOM anchors are kept as evidence; no personal page loaded.
"""
import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time


class ResourceServer(ThreadingHTTPServer):
    def __init__(self):
        super().__init__(("127.0.0.1", 0), ResourceHandler)
        self.counts = {}
        self.count_lock = threading.Lock()
        self.daemon_threads = True


class ResourceHandler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        # Only fixed synthetic names. Never log arbitrary paths, headers/cookies.
        if self.path not in {"/control.css", "/blocked.css", "/control.png", "/blocked.png"}:
            self.send_error(404)
            return
        with self.server.count_lock:
            self.server.counts[self.path] = self.server.counts.get(self.path, 0) + 1
        if self.path.endswith(".css"):
            data, kind = b"body { color: rgb(1, 2, 3); }", "text/css"
        else:
            data = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jD1sAAAAASUVORK5CYII=")
            kind = "image/png"
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", help="send the fixed public query once through actual WebKit")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    out = Path(tempfile.mkdtemp(prefix="woow-research-source-discovery-"))
    paths = ["Sources/AssistantBrowser/BrowserPolicy.swift", "Sources/AssistantBrowser/WebsiteKnowledgeSafety.swift",
             "Sources/AssistantBrowser/ResearchSourceDiscoveryTypes.swift", "Sources/AssistantBrowser/ResearchSourceDiscoveryWebKit.swift",
             "Tests/AssistantDomainTests/ResearchSourceDiscoveryTests.swift", "scripts/CheckResearchSourceDiscovery.swift",
             "scripts/check_research_source_discovery.py"]
    report = {"schema": 1, "status": "INCOMPLETE", "source_sha256": {}, "checks": [],
              "warnings_as_errors": True, "actual_source_closure": True, "production_source_substitutions": False,
              "native_ios_execution": False, "native_xctest_execution": False, "live_requested": args.live,
              "source_basis": "captured working-tree bytes; not a clean-commit claim",
              "limitations": ["macOS WebKit does not establish iOS acceptance",
                              "DOM/advertised Content-Length bounds do not limit all unknown-length network bytes",
                              "candidates are discovery leads, not read-body citation receipts",
                              "public provider availability and DOM may change; no fallback or CAPTCHA bypass"]}
    environment = {k: v for k, v in os.environ.items() if not k.startswith(("WOOW_MODEL_TEST_", "WOOW_HA_"))}
    def save():
        (out / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    def run(name, command, timeout):
        started = time.monotonic()
        process = subprocess.run(command, cwd=out, env=environment, capture_output=True, timeout=timeout)
        (out / (name + ".log")).write_bytes(process.stdout + process.stderr)
        check = {"name": name, "exit_code": process.returncode, "seconds": round(time.monotonic() - started, 3)}
        report["checks"].append(check); save()
        print(json.dumps(check), flush=True)
        if process.returncode:
            raise RuntimeError(name + "_failed")
    server = None
    try:
        for relative in paths:
            data = (repo / relative).read_bytes()
            report["source_sha256"][relative] = hashlib.sha256(data).hexdigest()
            destination = out / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
        common = ["swiftc", "-swift-version", "5", "-warnings-as-errors", "-parse-as-library"]
        run("compile-core", [*common, "-enable-testing", "-emit-module", "-emit-library", "-module-name", "AssistantBrowser",
            "-emit-module-path", str(out / "AssistantBrowser.swiftmodule"),
            *[str(out / p) for p in paths if p.startswith("Sources/")], "-o", str(out / "libAssistantBrowser.dylib")], 180)
        test, harness = out / paths[4], out / paths[5]
        run("parse-xctest", ["swiftc", "-frontend", "-parse", "-warnings-as-errors", str(test)], 30)
        run("compile-shared-checks", [*common, "-D", "RESEARCH_SOURCE_DISCOVERY_STANDALONE", "-I", str(out), "-L", str(out),
            "-lAssistantBrowser", "-Xlinker", "-rpath", "-Xlinker", str(out), str(test), str(harness), "-o", str(out / "checks")], 180)
        server = ResourceServer()
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        run("execute", [str(out / "checks"), str(out), "http://127.0.0.1:" + str(server.server_port),
                        *(["--live"] if args.live else [])], 100)
        report["result"] = json.loads((out / "result.json").read_text())
        with server.count_lock:
            report["local_resource_requests"] = dict(server.counts)
        counts = report["local_resource_requests"]
        if any(counts.get(p, 0) != 1 for p in ("/control.css", "/control.png")) or any(counts.get(p, 0) != 0 for p in ("/blocked.css", "/blocked.png")):
            raise RuntimeError("resource_control_or_block_failed")
        if report["result"]["status"] != "PASS":
            raise RuntimeError("assertion_failed")
        report["source_still_current"] = all(hashlib.sha256((repo / p).read_bytes()).hexdigest() == h for p, h in report["source_sha256"].items())
        if not report["source_still_current"]:
            raise RuntimeError("source_changed")
        report["status"] = "PASS"
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        report["status"] = "FAIL"
        report["failure"] = "process_deadline" if isinstance(error, subprocess.TimeoutExpired) else str(error)
        if (out / "result.json").exists():
            report["result"] = json.loads((out / "result.json").read_text())
        if (out / "live-result.json").exists():
            report["live_result"] = json.loads((out / "live-result.json").read_text())
    finally:
        if server:
            server.shutdown(); server.server_close()
            with server.count_lock:
                report["local_resource_requests"] = dict(server.counts)
        save()
        print("REPORT=" + str(out / "report.json"), flush=True)
    raise SystemExit(0 if report["status"] == "PASS" else 1)


if __name__ == "__main__":
    main()
