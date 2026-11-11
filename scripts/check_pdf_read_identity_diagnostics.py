#!/usr/bin/env python3
"""Real PDFKit/POSIX checks of bounded, local-fixture-only read-picker diagnostics."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ["Sources/App/SkillExecutionUITestSupport.swift", "Sources/App/PDFNativePicker.swift"]
SWIFT = r'''
import Foundation
import Darwin
#if DEBUG
import PDFKit
#endif
@main struct Check {
    enum Failure: Error { case assertion }
    static var assertions = 0
    static func check(_ value: Bool) throws {
        assertions += 1
        if !value { throw Failure.assertion }
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let id = UUID(uuidString: CommandLine.arguments[2])!
        let args = ["-UITestMode", "-UITestSkillExecution", "-UITestNamespace", id.uuidString]
        #if DEBUG
        let fixture = try SkillExecutionUITestSupport.seedIfRequested(arguments: args, documentsDirectory: { root })!
        typealias Support = SkillExecutionUITestSupport
        let pre = Support.readPickerSnapshot(fixture, phase: "prePicker", ordinal: 1, arguments: args)!
        try check(pre.evidence.status == "valid" && pre.evidence.bytes! > 0)
        try check(pre.location.parentInode != nil && pre.location.urlSHA256.count == 64)
        try check(pre.returnedURLRelation == "notReturned")
        let accepted = Support.readPickerSnapshot(fixture, phase: "selectionReturned", ordinal: 1,
            returnedURLs: [fixture.url], arguments: args)!
        try check(accepted.returnedURLRelation == "exactSource")
        try check(accepted.evidence.inode == pre.evidence.inode && accepted.evidence.sha256 == pre.evidence.sha256)
        let fifo = root.appendingPathComponent("unselected-sentinel")
        try check(mkfifo(fifo.path, 0o600) == 0)
        let other = Support.readPickerSnapshot(fixture, phase: "selectionReturned", ordinal: 1,
            returnedURLs: [fifo], arguments: args)!
        try check(other.returnedURLRelation == "other") // Would block if selected user URLs were opened.
        let uncreatedCopy = root.appendingPathComponent("not-created").appendingPathComponent(fixture.filename)
        let copy = Support.readPickerSnapshot(fixture, phase: "selectionReturned", ordinal: 1,
            returnedURLs: [uncreatedCopy], arguments: args)!
        try check(copy.returnedURLRelation == "sameBasenameOtherLocation")
        try check(!FileManager.default.fileExists(atPath: uncreatedCopy.path))
        let external = URL(string: "https://example.invalid/private-value")!
        try check(Support.readPickerSnapshot(fixture, phase: "selectionReturned", ordinal: 1,
            returnedURLs: [external], arguments: args)!.returnedURLRelation == "nonFile")
        try check(Support.readPickerSnapshot(fixture, phase: "selectionReturned", ordinal: 1,
            returnedURLs: [], arguments: args)!.returnedURLRelation == "empty")
        try check(Support.readPickerSnapshot(fixture, phase: "selectionReturned", ordinal: 1,
            returnedURLs: [fifo, external], arguments: args)!.returnedURLRelation == "multiple")
        let encoded = String(data: try JSONEncoder().encode(other), encoding: .utf8)!
        try check(!encoded.contains(root.path) && !encoded.contains("unselected-sentinel"))
        try check(!encoded.contains("private-value"))
        var invalidArguments: [[String]] = [[]]
        let additionalFlags = ["-UITestMode", "-UITestSkillExecution", "-LiveModelUITest", "-LiveMCPUITest", "-UITestSkillAssemblyPair"]
        for flag in additionalFlags { invalidArguments.append(args + [flag]) }
        invalidArguments.append(args + ["-UITestNamespace", id.uuidString])
        invalidArguments.append(["-UITestMode", "-UITestSkillExecution", "-UITestNamespace", id.uuidString.lowercased()])
        invalidArguments.append(["-UITestMode", "-UITestSkillExecution", "-UITestNamespace", UUID().uuidString])
        for invalid in invalidArguments {
            try check(Support.readPickerSnapshot(fixture, phase: "prePicker", ordinal: 1, arguments: invalid) == nil)
        }
        for ordinal in [0, 4, Int.max] {
            try check(Support.readPickerSnapshot(fixture, phase: "prePicker", ordinal: ordinal, arguments: args) == nil)
        }
        try check(Support.readPickerSnapshot(fixture, phase: "unknown", ordinal: 1, arguments: args) == nil)
        let forged = Support.Fixture(namespace: id, url: fifo)
        try check(Support.readPickerSnapshot(forged, phase: "prePicker", ordinal: 1, arguments: args) == nil)
        Support.recordReadPickerSnapshot(fixture, phase: "prePicker", ordinal: 1)
        Support.recordReadPickerSnapshot(fixture, phase: "selectionReturned", ordinal: 1, returnedURLs: [fixture.url])
        Support.recordReadPickerSnapshot(fixture, phase: "cancelled", ordinal: 2)
        let pdf = PDFDocument(url: fixture.url)!
        var attrs = pdf.documentAttributes!
        attrs[PDFDocumentAttribute.subjectAttribute] = "replaced synthetic fixture"
        pdf.documentAttributes = attrs
        try pdf.dataRepresentation()!.write(to: fixture.url, options: .atomic)
        let replaced = Support.readPickerSnapshot(fixture, phase: "prePicker", ordinal: 2, arguments: args)!
        try check(replaced.evidence.status == "valid")
        try check(replaced.evidence.inode != pre.evidence.inode && replaced.evidence.sha256 != pre.evidence.sha256)
        try check(replaced.location.urlSHA256 == pre.location.urlSHA256)
        try check(replaced.location.parentInode == pre.location.parentInode)
        try FileManager.default.removeItem(at: fixture.url)
        try check(Support.readPickerSnapshot(fixture, phase: "prePicker", ordinal: 3, arguments: args)!.evidence.status == "missing")
        try FileManager.default.createSymbolicLink(at: fixture.url, withDestinationURL: fifo)
        try check(Support.readPickerSnapshot(fixture, phase: "prePicker", ordinal: 3, arguments: args)!.evidence.status == "openRejected")
        try check(PDFNativePickerExperiment.configuration(arguments: args, fixtureNamespace: id) != nil)
        try check(PDFNativePickerExperiment.configuration(arguments: args + ["-LiveModelUITest"], fixtureNamespace: id) == nil)
        #else
        var touched = false
        let fixture = try SkillExecutionUITestSupport.seedIfRequested(arguments: args, documentsDirectory: {
            touched = true; return root
        })
        try check(fixture == nil && !touched)
        try check(PDFNativePickerExperiment.configuration(arguments: args, fixtureNamespace: id) == nil)
        #endif
        print("READ_PICKER_CHECK assertions=\(assertions)")
    }
}
'''


def main():
    hashes = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in SOURCES}
    results = {}
    with tempfile.TemporaryDirectory(prefix="woow-read-picker-") as temporary:
        work = Path(temporary)
        harness = work / "Check.swift"
        harness.write_text(SWIFT)
        for mode in ("Debug", "Release"):
            binary = work / mode
            command = ["swiftc", "-warnings-as-errors", "-parse-as-library"]
            if mode == "Debug":
                command += ["-D", "DEBUG"]
            command += [str(ROOT / p) for p in SOURCES] + [str(harness), "-o", str(binary)]
            compiled = subprocess.run(command, timeout=120, capture_output=True, text=True)
            if compiled.returncode != 0:
                raise RuntimeError(compiled.stderr[:6000])
            directory = work / (mode + "-files")
            directory.mkdir()
            namespace = str(uuid.uuid4()).upper()
            result = subprocess.run([str(binary), str(directory), namespace, "-UITestMode", "-UITestSkillExecution",
                                     "-UITestNamespace", namespace], check=True, timeout=20, capture_output=True, text=True)
            records = [json.loads(line.split(" ", 1)[1]) for line in result.stdout.splitlines()
                       if line.startswith("SKILL_PDF_READ_PICKER_IDENTITY ")]
            assert len(records) == (3 if mode == "Debug" else 0)
            assert all(str(directory) not in json.dumps(r) for r in records)
            if records:
                assert [r["phase"] for r in records] == ["prePicker", "selectionReturned", "cancelled"]
                assert [r["returnedURLRelation"] for r in records] == ["notReturned", "exactSource", "notReturned"]
            results[mode] = next(line for line in result.stdout.splitlines() if line.startswith("READ_PICKER_CHECK "))
    assert hashes == {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in SOURCES}
    print(json.dumps({"results": results, "source_sha256": hashes, "native_ios_execution": False}))


if __name__ == "__main__":
    main()
