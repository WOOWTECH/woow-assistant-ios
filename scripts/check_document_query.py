#!/usr/bin/env python3
"""Compile real Models/Skills and run the same PDFKit checks as native XCTest.

No model service, arbitrary document, mock PDF parser or replacement runtime.
The temporary source snapshot makes concurrent shared-tree edits detectable.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    repo = Path(__file__).resolve().parents[1]
    paths = sorted([*repo.glob("Sources/AssistantModels/*.swift"),
                    *repo.glob("Sources/AssistantSkills/*.swift"),
                    repo / "Sources/AssistantSkills/Resources/MikaBundledSkills.json",
                    repo / "Tests/AssistantSkillsTests/DocumentQueryTests.swift",
                    Path(__file__).resolve()])
    with tempfile.TemporaryDirectory(prefix="woow-document-query-") as temporary:
        build = Path(temporary)
        hashes = {}
        for path in paths:
            relative = path.relative_to(repo)
            data = path.read_bytes()
            hashes[str(relative)] = hashlib.sha256(data).hexdigest()
            target = build / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        common = ["swiftc", "-swift-version", "5", "-warnings-as-errors", "-parse-as-library"]
        for module, dependencies in [("AssistantModels", []), ("AssistantSkills", ["-lAssistantModels"])]:
            subprocess.run([*common, "-enable-testing", "-emit-module", "-emit-library",
                            "-module-name", module, "-emit-module-path", str(build / (module + ".swiftmodule")),
                            "-I", str(build), "-L", str(build), *dependencies,
                            *map(str, sorted((build / "Sources" / module).glob("*.swift"))),
                            "-o", str(build / ("lib" + module + ".dylib"))], check=True, timeout=240)
        test = build / "Tests/AssistantSkillsTests/DocumentQueryTests.swift"
        subprocess.run(["swiftc", "-frontend", "-parse", "-warnings-as-errors", str(test)], check=True, timeout=60)
        subprocess.run([*common, "-D", "DOCUMENT_QUERY_STANDALONE", "-I", str(build), "-L", str(build),
                        "-lAssistantModels", "-lAssistantSkills", "-Xlinker", "-rpath", "-Xlinker", str(build),
                        str(test), "-o", str(build / "checks")], check=True, timeout=180)
        process = subprocess.run([str(build / "checks"),
                                  str(build / "Sources/AssistantSkills/Resources/MikaBundledSkills.json")],
                                 capture_output=True, text=True, timeout=120)
        print(process.stdout, end="", flush=True)
        if process.returncode:
            print(process.stderr, end="", flush=True)
            raise subprocess.CalledProcessError(process.returncode, "document-query-checks")
        current = all(hashlib.sha256((repo / path).read_bytes()).hexdigest() == digest
                      for path, digest in hashes.items())
        report = {"schema": 1, "status": "PASS", "source_still_current": current,
                  "shared_test_body": "DocumentQueryTests.swift", "warnings_as_errors": True,
                  "real_pdfkit": True, "network_requests": 0, "native_xctest_execution": False,
                  "results": process.stdout.splitlines(), "source_sha256": hashes}
        report_path = Path(tempfile.gettempdir()) / "woow-document-query-local.json"
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print("DOCUMENT_QUERY_SOURCE_CURRENT=" + str(current).lower())
        print("REPORT=" + str(report_path))
        if not current:
            raise SystemExit("DOCUMENT_QUERY_SOURCE_CHANGED")


if __name__ == "__main__":
    try:
        main()
    except subprocess.TimeoutExpired:
        raise SystemExit("DOCUMENT_QUERY_CHECK_TIMEOUT")
    except subprocess.CalledProcessError:
        raise SystemExit("DOCUMENT_QUERY_CHECK_FAILED")
