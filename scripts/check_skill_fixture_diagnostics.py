#!/usr/bin/env python3
"""Real macOS PDFKit/POSIX acceptance for the DEBUG baseline and host inventory.
Run: python3 scripts/check_skill_fixture_diagnostics.py
No simulator, network, dependency installation or user files are used.
"""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

REPO = Path(__file__).resolve().parent.parent
SUPPORT = REPO / "Sources/App/SkillExecutionUITestSupport.swift"
BUILDER = r'''
import Foundation
import Darwin
import PDFKit
@main struct Fixtures {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var names: [String: String] = [:]
        var fixtures: [String: SkillExecutionUITestSupport.Fixture] = [:]
        for name in ["unchanged", "replaced", "missing", "oversized", "symlink", "hardlink", "directory", "wrongTitle", "wrongAuthor"] {
            let id = UUID()
            let args = ["-UITestMode", "-UITestSkillExecution", "-UITestNamespace", id.uuidString]
            let fixture = try SkillExecutionUITestSupport.seedIfRequested(arguments: args, documentsDirectory: { root })!
            if CommandLine.arguments.count == 3 { _exit(0) } // No normal stdio exit flush.
            fixtures[name] = fixture; names[name] = id.uuidString
            if name == "unchanged" {
                _ = try SkillExecutionUITestSupport.seedIfRequested(arguments: args, documentsDirectory: { root })
            }
        }
        for name in ["replaced", "wrongTitle", "wrongAuthor"] {
            let url = fixtures[name]!.url
            let pdf = PDFDocument(url: url)!
            var attrs = pdf.documentAttributes!
            if name == "wrongTitle" { attrs[PDFDocumentAttribute.titleAttribute] = "not the synthetic fixture" }
            else if name == "wrongAuthor" { attrs[PDFDocumentAttribute.authorAttribute] = "not the synthetic author" }
            else { attrs[PDFDocumentAttribute.subjectAttribute] = "replacement fixture bytes" }
            pdf.documentAttributes = attrs
            try pdf.dataRepresentation()!.write(to: url, options: .atomic)
        }
        try FileManager.default.removeItem(at: fixtures["missing"]!.url)
        try Data(repeating: 0, count: 128 * 1024 + 1).write(to: fixtures["oversized"]!.url)
        for name in ["symlink", "hardlink", "directory"] { try FileManager.default.removeItem(at: fixtures[name]!.url) }
        let sentinel = root.appendingPathComponent("unrelated-sentinel.txt")
        try Data("DO_NOT_READ_OR_EXPORT".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: fixtures["symlink"]!.url, withDestinationURL: sentinel)
        // A hard link is rejected before PDF parsing, even within this test root.
        try FileManager.default.linkItem(at: sentinel, to: fixtures["hardlink"]!.url)
        try FileManager.default.createDirectory(at: fixtures["directory"]!.url, withIntermediateDirectories: false)
        try JSONEncoder().encode(names).write(to: root.deletingLastPathComponent().appendingPathComponent("names.json"))
    }
}
'''


def run(args):
    return subprocess.run([str(a) for a in args], capture_output=True, text=True, check=True, timeout=60)


def main():
    spec = importlib.util.spec_from_file_location("collector", REPO / "scripts/copy_skill_fixture_diagnostics.py")
    collector = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(collector)
    with tempfile.TemporaryDirectory(prefix="woow-fixture-diagnostics-check-") as work:
        work = Path(work)
        builder_source = work / "Fixtures.swift"
        builder_source.write_text(BUILDER)
        run(["swiftc", "-DDEBUG", "-parse-as-library", SUPPORT, builder_source, "-o", work / "fixtures"])
        run(["swiftc", "-DDEBUG", "-parse-as-library", SUPPORT, REPO / "scripts/SkillFixtureInventory.swift", "-o", work / "inventory"])
        abrupt = run([work / "fixtures", work / "abrupt-exit", "force-exit"])
        abrupt_lines = [line for line in abrupt.stdout.splitlines() if line.startswith(collector.MARKER)]
        assert len(abrupt_lines) == 1
        assert collector.checked(json.loads(abrupt_lines[0][len(collector.MARKER):]))["evidence"]["status"] == "valid"
        created = run([work / "fixtures", work / "Documents"])
        logs = work / "diagnostics"
        logs.mkdir()
        (logs / "StandardOutputAndStandardError-io.woowtech.assistant.txt").write_text(created.stdout)
        baselines = collector.baselines_from_logs(logs)
        assert len(baselines) == 9 and all(b["phase"] == "created" for b in baselines)
        assert all(b["evidence"]["status"] == "valid" for b in baselines)
        baseline_file = work / "baselines.json"
        baseline_file.write_text(json.dumps(baselines))
        report_file = work / "report.json"
        run([work / "inventory", work / "Documents", baseline_file, report_file])
        report = json.loads(report_file.read_text())
        assert report["provesPresenceAtEarlierPickerFailure"] is False
        names = json.loads((work / "names.json").read_text())
        entries = {e["baseline"]["namespace"]: e for e in report["entries"]}
        unchanged = entries[names["unchanged"]]
        assert unchanged["sameHash"] and unchanged["sameSize"] and unchanged["sameIdentity"]
        replacement = entries[names["replaced"]]
        assert replacement["current"]["status"] == "valid" and not replacement["sameHash"] and not replacement["sameIdentity"]
        expected = {"missing": "missing", "oversized": "oversized", "symlink": "openRejected", "hardlink": "unsafeFile",
                    "directory": "unsafeFile", "wrongTitle": "invalidFixture", "wrongAuthor": "invalidFixture"}
        for case, status in expected.items():
            entry = entries[names[case]]
            assert entry["current"]["status"] == status, (case, entry)
            assert "sha256" not in entry["current"] and "sameHash" not in entry
        assert "DO_NOT_READ_OR_EXPORT" not in report_file.read_text() and str(work) not in report_file.read_text()
        assert (work / "Documents/unrelated-sentinel.txt").read_text() == "DO_NOT_READ_OR_EXPORT"
        link = work / "linked-directory"
        link.symlink_to(work / "Documents", target_is_directory=True)
        run([work / "inventory", link, baseline_file, report_file])
        assert all(e["current"]["status"] == "directoryUnavailable" for e in json.loads(report_file.read_text())["entries"])
        for key, value in [("namespace", "../user.pdf"), ("phase", "user"), ("version", True)]:
            bad = copy.deepcopy(baselines[0]); bad[key] = value
            try: collector.checked(bad)
            except (ValueError, TypeError): pass
            else: raise AssertionError(key)
        bad = copy.deepcopy(baselines[0]); bad["evidence"]["bytes"] = 128 * 1024 + 1
        try: collector.checked(bad)
        except ValueError: pass
        else: raise AssertionError("oversized baseline accepted")
        # Exercise the actual collector's absence/error paths without simctl;
        # neither may report a valid inventory or inspect Documents.
        empty_logs = work / "empty-logs"
        empty_logs.mkdir()
        collector_script = REPO / "scripts/copy_skill_fixture_diagnostics.py"
        run([sys.executable, collector_script, str(uuid.uuid4()), empty_logs, report_file])
        unavailable = json.loads(report_file.read_text())
        assert unavailable["observation"] == "unavailable" and unavailable["reason"] == "no-debug-baselines"
        (empty_logs / "StandardOutputAndStandardError-io.woowtech.assistant.txt").write_text(collector.MARKER + '{"secret":"never-export-this"}\n')
        run([sys.executable, collector_script, str(uuid.uuid4()), empty_logs, report_file])
        unavailable = json.loads(report_file.read_text())
        assert unavailable["observation"] == "unavailable" and unavailable["reason"] == "baselines-unavailable-or-rejected"
        assert "never-export-this" not in report_file.read_text()
        # The existing exact seeder checks also verify inactive/invalid gates and
        # Release's zero filesystem access, with the new baseline code compiled out.
        original_checks = REPO / "Tests/WoowAssistantUITests/SkillExecutionUITests.swift"
        for mode in [[], ["-DDEBUG"]]:
            binary = work / ("debug-gates" if mode else "release-gates")
            run(["swiftc", *mode, "-D", "SKILL_EXECUTION_UI_FIXTURE_CHECKS", "-parse-as-library", SUPPORT, original_checks, "-o", binary])
            run([binary])
    print("PASS real PDF seed baselines including abrupt _exit; unchanged/replaced/missing files; byte limit; symbolic/hard/directory links; metadata refusal; strict log schema; DEBUG/Release gates")


if __name__ == "__main__":
    main()
