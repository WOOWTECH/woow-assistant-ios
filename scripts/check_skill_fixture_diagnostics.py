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

LIVE_GATES = r'''
import Foundation
#if DEBUG
import PDFKit
#endif
@main struct LiveGates {
    enum Failure: Error { case check }
    static func require(_ value: Bool) throws { if !value { throw Failure.check } }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let id = UUID()
        let live = ["-LiveModelUITest", "-LiveModelUITestNamespace", id.uuidString, "-UITestSkillExecution"]
        let invalid: [[String]] = [
            live + ["-UITestMode"], live + ["-UITestNamespace", UUID().uuidString],
            live + ["-LiveModelUITest"], live + ["-UITestSkillExecution"],
            live + ["-LiveModelUITestNamespace", UUID().uuidString],
            live + ["-LiveModelUITestCleanup"], live + ["-LiveMCPUITest"],
            live + ["-UITestPDFUIKitPicker"], live + ["-UITestPDFUIKitCopyPicker"],
            live + ["-UITestPDFAssemblyUIKitOpen"], live + ["-UITestPDFAssemblyUIKitOpenMulti"],
            live + ["-UITestPDFAssemblyUIKitOpen=1"], live + ["-UITestPDFAssemblyUnknown"],
            live + ["-UITestSkillFixtureWriteMode", "coordinated"],
            ["-LiveModelUITest", "-LiveModelUITestNamespace", "../outside", "-UITestSkillExecution"],
            ["-LiveModelUITestNamespace", id.uuidString, "-UITestSkillExecution"],
            ["-LiveModelUITest", "-UITestSkillExecution"],
            ["-UITestMode", "-UITestNamespace", id.uuidString, "-UITestSkillExecution", "-LiveModelUITestNamespace", id.uuidString]
        ]
        for args in invalid {
            var touched = false
            do {
                let ignored = try SkillExecutionUITestSupport.seedIfRequested(arguments: args) {
                    touched = true; throw Failure.check
                }
                #if DEBUG
                _ = ignored; throw Failure.check
                #else
                try require(ignored == nil)
                #endif
            } catch SkillExecutionUITestSupport.Failure.invalidNamespace { }
            try require(!touched)
        }
        #if DEBUG
        let seeded = try SkillExecutionUITestSupport.seedIfRequested(arguments: live, documentsDirectory: { root })
        guard let fixture = seeded, let document = PDFDocument(url: fixture.url) else { throw Failure.check }
        try require(document.pageCount == 2 && fixture.filename == "SkillExecution-" + id.uuidString + ".pdf")
        for page in 1...2 {
            let text = document.page(at: page - 1)?.string ?? ""
            try require(text.contains("WOOW_SKILL_PDF_PAGE_\(page)") && text.contains(id.uuidString))
        }
        let before = try Data(contentsOf: fixture.url)
        _ = try SkillExecutionUITestSupport.seedIfRequested(arguments: live, documentsDirectory: { root })
        try require(try Data(contentsOf: fixture.url) == before)
        let audit = SkillExecutionUITestAudit()
        try require(audit.selections == 0 && audit.reads == 0 && audit.extractionAttempts == 0 && audit.results == 0)
        let sentinel = Data("unowned live fixture sentinel".utf8)
        try sentinel.write(to: fixture.url)
        do {
            _ = try SkillExecutionUITestSupport.seedIfRequested(arguments: live, documentsDirectory: { root })
            throw Failure.check
        } catch SkillExecutionUITestSupport.Failure.existingFile { }
        try require(try Data(contentsOf: fixture.url) == sentinel)
        #else
        var touched = false
        let ignored = try SkillExecutionUITestSupport.seedIfRequested(arguments: live) {
            touched = true; throw Failure.check
        }
        try require(ignored == nil && !touched)
        #endif
        // Any seeder inventory/private output makes the outer check fail.
    }
}
'''

PAIR_BUILDER = r'''
import Foundation
import PDFKit
@main struct PairFixtures {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var names: [String: String] = [:]
        for name in ["unchanged", "replacedA", "missingB", "wrongRoleA"] {
            let id = UUID(); names[name] = id.uuidString
            let args = ["-UITestMode", "-UITestSkillExecution", "-UITestNamespace", id.uuidString, "-UITestSkillAssemblyPair"]
            let pair = try SkillExecutionUITestSupport.seedAssemblyPairIfRequested(arguments: args, documentsDirectory: { root })!
            SkillExecutionUITestSupport.recordPairSnapshot(pair, phase: "prePicker", ordinal: 1)
            if name == "replacedA" {
                let pdf = PDFDocument(url: pair.sources[0].url)!
                var attrs = pdf.documentAttributes!
                attrs[PDFDocumentAttribute.subjectAttribute] = "changed synthetic bytes"
                pdf.documentAttributes = attrs
                try pdf.dataRepresentation()!.write(to: pair.sources[0].url, options: .atomic)
            } else if name == "missingB" {
                try FileManager.default.removeItem(at: pair.sources[1].url)
            } else if name == "wrongRoleA" {
                try Data(contentsOf: pair.sources[1].url).write(to: pair.sources[0].url, options: .atomic)
            }
            SkillExecutionUITestSupport.recordPairSnapshot(pair, phase: "prePicker", ordinal: 2)
            // Invalid observations cannot produce an extra log or filesystem read.
            SkillExecutionUITestSupport.recordPairSnapshot(pair, phase: "arbitrary", ordinal: 1)
            SkillExecutionUITestSupport.recordPairSnapshot(pair, phase: "prePicker", ordinal: 4)
        }
        try JSONEncoder().encode(names).write(to: root.deletingLastPathComponent().appendingPathComponent("pair-names.json"))
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
        pair_source = work / "PairFixtures.swift"
        pair_source.write_text(PAIR_BUILDER)
        run(["swiftc", "-DDEBUG", "-parse-as-library", SUPPORT, pair_source, "-o", work / "pair-fixtures"])
        pair_root = work / "PairDocuments"
        pair_created = run([work / "pair-fixtures", pair_root])
        assert str(work) not in pair_created.stdout and "WOOW_ASSEMBLY_" not in pair_created.stdout
        pair_logs = work / "pair-logs"; pair_logs.mkdir()
        pair_log = pair_logs / "StandardOutputAndStandardError-io.woowtech.assistant.txt"
        pair_log.write_text(pair_created.stdout)
        snapshots = collector.baselines_from_logs(pair_logs)
        assert len(snapshots) == 24 and all(b["version"] == 2 for b in snapshots)
        pair_names = json.loads((work / "pair-names.json").read_text())
        baseline_file.write_text(json.dumps(snapshots))
        run([work / "inventory", pair_root, baseline_file, report_file])
        pair_report = json.loads(report_file.read_text())
        assert pair_report["observation"] == "post-test-only" and not pair_report["provesPresenceAtEarlierPickerFailure"]
        def pair_entry(name, role, phase="created", ordinal=0):
            return next(e for e in pair_report["entries"] if e["baseline"]["namespace"] == pair_names[name]
                        and e["baseline"]["role"] == role and e["baseline"]["phase"] == phase
                        and e["baseline"]["ordinal"] == ordinal)
        for role in ("A", "B"):
            for phase, ordinal in [("created", 0), ("prePicker", 1), ("prePicker", 2)]:
                e = pair_entry("unchanged", role, phase, ordinal)
                assert all(e[key] for key in ("sameHash", "sameSize", "sameIdentity", "sameSourceURL", "sameParentIdentity"))
        changed = pair_entry("replacedA", "A")
        assert changed["current"]["status"] == "valid" and not changed["sameHash"] and not changed["sameIdentity"]
        assert changed["sameSourceURL"] and changed["sameParentIdentity"]
        assert pair_entry("replacedA", "A", "prePicker", 2)["sameHash"]
        assert pair_entry("replacedA", "B")["sameHash"]
        for name, role, status in [("missingB", "B", "missing"), ("wrongRoleA", "A", "invalidFixture")]:
            e = pair_entry(name, role)
            assert e["current"]["status"] == status and "sameHash" not in e
            assert pair_entry(name, role, "prePicker", 2)["baseline"]["evidence"]["status"] == status
        # Identity and path remain independent: the same basename in a different
        # directory is not evidence for the original selected source location.
        other = work / "DifferentDocuments"; other.mkdir()
        run([work / "inventory", other, baseline_file, report_file])
        moved = json.loads(report_file.read_text())["entries"]
        assert all(e["current"]["status"] == "missing" and not e["sameSourceURL"] and not e["sameParentIdentity"] for e in moved)
        pair_root.rename(work / "PreviousPairDocuments"); pair_root.mkdir()
        run([work / "inventory", pair_root, baseline_file, report_file])
        recreated = json.loads(report_file.read_text())["entries"]
        assert all(e["current"]["status"] == "missing" and e["sameSourceURL"] and not e["sameParentIdentity"] for e in recreated)
        for key, value in [("role", "../outside"), ("ordinal", True), ("ordinal", 4), ("phase", "postTests")]:
            bad = copy.deepcopy(snapshots[0]); bad[key] = value
            try: collector.checked(bad)
            except (ValueError, TypeError): pass
            else: raise AssertionError("pair schema accepted " + key)
        bad = copy.deepcopy(snapshots[0]); bad["location"]["urlSHA256"] = "/private/path"
        try: collector.checked(bad)
        except ValueError: pass
        else: raise AssertionError("pair raw path accepted")
        for log in [pair_created.stdout + pair_created.stdout.splitlines()[0] + "\n",
                    collector.MARKER + json.dumps(snapshots[0]) + "\n"]:
            pair_log.write_text(log)
            try: collector.baselines_from_logs(pair_logs)
            except ValueError: pass
            else: raise AssertionError("duplicate or crossed pair schema accepted")
        # The existing exact seeder checks also verify inactive/invalid gates and
        # Release's zero filesystem access, with the new baseline code compiled out.
        original_checks = REPO / "Tests/WoowAssistantUITests/SkillExecutionUITests.swift"
        live_checks = work / "LiveGates.swift"
        live_checks.write_text(LIVE_GATES)
        for mode in [[], ["-DDEBUG"]]:
            binary = work / ("debug-gates" if mode else "release-gates")
            run(["swiftc", *mode, "-D", "SKILL_EXECUTION_UI_FIXTURE_CHECKS", "-parse-as-library", SUPPORT, original_checks, "-o", binary])
            run([binary])
            live_binary = work / ("debug-live-gates" if mode else "release-live-gates")
            run(["swiftc", *mode, "-parse-as-library", SUPPORT, live_checks, "-o", live_binary])
            live_result = run([live_binary, work / "LiveDocuments"])
            assert live_result.stdout == "", "Live seeding must not print file inventory or source content"
    print("PASS real PDF seed baselines including abrupt _exit; unchanged/replaced/missing files; byte limit; symbolic/hard/directory links; metadata refusal; strict log schema; DEBUG/Release gates")
    print("PASS live PDFKit source, 17 invalid/mixed/cleanup gates before file access, idempotence, overwrite refusal, zero runtime audit, silent live output and Release no-file-access")
    print("PASS pair lifecycle: 24 real snapshots; A/B role validation; replacement/missing source; path versus parent identity; immutable earlier samples; strict marker/schema/ordinal bounds; post-test-only limitation")


if __name__ == "__main__":
    main()
