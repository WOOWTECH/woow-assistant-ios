#!/usr/bin/env python3
"""Snapshot and check the opt-in fixture experiment with real PDFKit/NSFileCoordinator.
No simulator, native file selection, export, provider repair or acceptance claim.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import tempfile
from check_pdf_assembly_pair import run
from copy_skill_fixture_diagnostics import PAIR_MARKER, checked

FLAG = '-UITestSkillAssemblyPairDirectoryCoordinatedCreation'
SWIFT = r'''
import Foundation
import Darwin
#if DEBUG
import CryptoKit
import PDFKit
#endif
@main struct CheckDirectoryCreation {
    typealias Support = SkillExecutionUITestSupport
    struct Failed: Error { let code: String }
    static var groups: [String: Int] = [:]
    static var group = "gates"
    static func check(_ condition: @autoclosure () throws -> Bool, _ code: String) throws {
        guard try condition() else { throw Failed(code: code) }
        groups[group, default: 0] += 1
    }
    static func mustReject(_ body: () throws -> Void) throws {
        do { try body(); throw Failed(code: "unexpected_success") }
        catch is Support.Failure { groups[group, default: 0] += 1 }
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let id = UUID(uuidString: "A1234567-89AB-4CDE-8123-456789ABCDEF")!
        let base = "-UITestSkillAssemblyPair"
        let flag = "-UITestSkillAssemblyPairDirectoryCoordinatedCreation"
        let args = ["-UITestMode", "-UITestSkillExecution", "-UITestNamespace", id.uuidString, base]
        let candidate = args + [flag]
        var invalid: [[String]] = []
        invalid.append(candidate + [flag])
        invalid.append(candidate + [base])
        invalid.append(candidate + [base + "Unknown"])
        invalid.append(args + [flag + "=1"])
        invalid.append(candidate.filter { $0 != base })
        invalid.append(candidate.filter { $0 != "-UITestMode" })
        invalid.append(candidate.filter { $0 != "-UITestSkillExecution" })
        invalid.append(candidate.filter { $0 != "-UITestNamespace" })
        invalid.append(candidate + ["-UITestMode"])
        invalid.append(candidate + ["-UITestSkillExecution"])
        invalid.append(candidate + ["-UITestNamespace", id.uuidString])
        invalid.append(candidate.map { $0 == id.uuidString ? id.uuidString.lowercased() : $0 })
        invalid.append(candidate.map { $0 == id.uuidString ? "../outside" : $0 })
        invalid.append(candidate + ["-LiveModelUITest"])
        invalid.append(candidate + ["-LiveModelUITestNamespace", id.uuidString])
        invalid.append(candidate + ["-LiveMCPUITest"])
        invalid.append(candidate + ["-UITestPDFAssemblyUIKitOpen"])
        invalid.append(candidate + ["-UITestSkillFixtureWriteMode", "coordinated"])
        for arguments in invalid {
            var touched = false
            #if DEBUG
            try mustReject {
                _ = try Support.seedAssemblyPairIfRequested(arguments: arguments,
                    documentsDirectory: { touched = true; return root })
            }
            try check(!touched, "gate_before_IO")
            #endif
            // Single-file and Live entry must not consume the experiment either.
            do {
                let result = try Support.seedIfRequested(arguments: arguments, documentsDirectory: {
                    touched = true; return root
                })
                try check(result == nil, "single_entry_inactive")
            } catch Support.Failure.invalidNamespace {
                groups[group, default: 0] += 1
            }
            try check(!touched, "single_entry_no_IO")
        }
        #if DEBUG
        group = "actual_creation"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directDirectory = root.appendingPathComponent("direct", isDirectory: true)
        let unusedCoordinator = NSFileCoordinator()
        unusedCoordinator.cancel()
        let direct = try Support.seedAssemblyPairIfRequested(arguments: args,
            directoryCoordinator: unusedCoordinator, documentsDirectory: { directDirectory })!
        try check(direct.sources.count == 2, "direct_ignores_cancelled_coordinator")
        try check(direct.creationProof.accessibilityValue == "creation=direct coordinationAttempts=0 accessorCalls=0 createdFiles=2 existingFiles=0", "direct_proof")
        let directory = root.appendingPathComponent("candidate", isDirectory: true)
        let fixture = try Support.seedAssemblyPairIfRequested(arguments: candidate,
            directoryCoordinator: NSFileCoordinator(), documentsDirectory: { directory })!
        try check(fixture.creationProof.coordinationAttempts == 1, "one_actual_coordination")
        try check(fixture.creationProof.accessibilityValue == "creation=directoryCoordinated coordinationAttempts=1 accessorCalls=1 createdFiles=2 existingFiles=0", "candidate_proof")
        try check(fixture.namespace == id && fixture.sources.count == 2, "two_sources")
        try check(Set(fixture.sources.map(\.sha256)).count == 2, "distinct_bytes")
        var identities: [String: UInt64] = [:]
        var originals: [String: Data] = [:]
        for (index, role) in ["A", "B"].enumerated() {
            let source = fixture.sources[index]
            try check(source.role == role, "exact_role")
            try check(source.url == directory.appendingPathComponent("SkillAssembly-\(role)-\(id.uuidString).pdf"), "exact_path")
            let bytes = try Data(contentsOf: source.url)
            originals[role] = bytes
            try check(bytes.count > 0 && bytes.count <= 128 * 1024, "bounded_pdf")
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            try check(digest == source.sha256, "actual_bytes_digest")
            let pdf = PDFDocument(data: bytes)!, baseline = PDFDocument(url: direct.sources[index].url)!
            try check(pdf.pageCount == 2 && baseline.pageCount == 2, "two_actual_pages")
            try check(pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "WOOW_ASSEMBLY_\(role)_\(id.uuidString)", "same_title")
            for page in 0..<2 {
                try check(pdf.page(at: page)!.string == baseline.page(at: page)!.string, "same_page_text")
                try check(pdf.page(at: page)!.bounds(for: .mediaBox) == baseline.page(at: page)!.bounds(for: .mediaBox), "same_geometry")
                try check(pdf.page(at: page)!.rotation == baseline.page(at: page)!.rotation, "same_rotation")
            }
            let sample = Support.pairFixtureSample(in: directory, namespace: id, role: role)
            try check(sample.0.status == "valid" && sample.0.sha256 == digest, "same_POSIX_observer")
            identities[role] = sample.0.inode!
        }
        group = "idempotence"
        let again = try Support.seedAssemblyPairIfRequested(arguments: candidate, documentsDirectory: { directory })!
        try check(again.creationProof.accessibilityValue == "creation=directoryCoordinated coordinationAttempts=1 accessorCalls=1 createdFiles=0 existingFiles=2", "existing_not_overwritten")
        for source in again.sources {
            try check(try Data(contentsOf: source.url) == originals[source.role]!, "original_bytes_retained")
            let sample = Support.pairFixtureSample(in: directory, namespace: id, role: source.role)
            try check(sample.0.inode == identities[source.role]!, "original_inode_retained")
        }
        group = "cancelled_coordination"
        let cancelledDirectory = root.appendingPathComponent("cancelled", isDirectory: true)
        let cancelled = NSFileCoordinator()
        cancelled.cancel() // Real public cancellation, not a stubbed callback.
        try mustReject {
            _ = try Support.seedAssemblyPairIfRequested(arguments: candidate, directoryCoordinator: cancelled,
                documentsDirectory: { cancelledDirectory })
        }
        try check(try FileManager.default.contentsOfDirectory(atPath: cancelledDirectory.path).isEmpty, "no_fallback_after_cancel")
        group = "directory_identity"
        let identity = try Support.assemblyPairDirectoryIdentity(directory)
        try Support.validateAssemblyPairDirectory(directory, expected: directory, identity: identity)
        try check(true, "same_directory_accepted")
        try mustReject { try Support.validateAssemblyPairDirectory(directDirectory, expected: directory, identity: identity) }
        try mustReject { try Support.validateAssemblyPairDirectory(URL(string: "https://example.invalid/")!, expected: directory, identity: identity) }
        let linked = root.appendingPathComponent("linked-directory", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: directory)
        try mustReject { _ = try Support.assemblyPairDirectoryIdentity(linked) }
        let moved = root.appendingPathComponent("replaced-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: false)
        let oldIdentity = try Support.assemblyPairDirectoryIdentity(moved)
        let original = root.appendingPathComponent("original-directory", isDirectory: true)
        try FileManager.default.moveItem(at: moved, to: original)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: false)
        try mustReject { try Support.validateAssemblyPairDirectory(moved, expected: moved, identity: oldIdentity) }
        group = "unsafe_existing_files"
        for kind in ["invalid", "symlink", "hardlink", "fifo", "oversized"] {
            let badDirectory = root.appendingPathComponent(kind, isDirectory: true)
            try FileManager.default.createDirectory(at: badDirectory, withIntermediateDirectories: false)
            let a = badDirectory.appendingPathComponent("SkillAssembly-A-\(id.uuidString).pdf")
            let b = badDirectory.appendingPathComponent("SkillAssembly-B-\(id.uuidString).pdf")
            let sentinel = badDirectory.appendingPathComponent("sentinel")
            let sentinelBytes = Data("UNCHANGED_SYNTHETIC_SENTINEL".utf8)
            try sentinelBytes.write(to: sentinel)
            switch kind {
            case "invalid": try sentinelBytes.write(to: b)
            case "symlink": try FileManager.default.createSymbolicLink(at: b, withDestinationURL: sentinel)
            case "hardlink": try FileManager.default.linkItem(at: sentinel, to: b)
            case "fifo": try check(mkfifo(b.path, 0o600) == 0, "fixture_FIFO")
            default: try Data(repeating: 0, count: 128 * 1024 + 1).write(to: b)
            }
            try mustReject {
                _ = try Support.seedAssemblyPairIfRequested(arguments: candidate, documentsDirectory: { badDirectory })
            }
            try check(!FileManager.default.fileExists(atPath: a.path), "invalid_B_prevents_A_write")
            try check(try Data(contentsOf: sentinel) == sentinelBytes, "unrelated_sentinel_preserved")
        }
        #else
        var touched = false
        let ignored = try Support.seedIfRequested(arguments: candidate, documentsDirectory: { touched = true; return root })
        try check(ignored == nil && !touched, "release_inert")
        try check(!FileManager.default.fileExists(atPath: root.path), "release_no_directory")
        #endif
        let payload: [String: Any] = ["groups": groups, "passed": groups.values.reduce(0, +), "native_picker_UI": false]
        let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        print("DIRECTORY_CREATION_CHECKS " + String(decoding: bytes, as: UTF8.self))
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    names = ['Sources/App/SkillExecutionUITestSupport.swift', 'Sources/App/SkillPDFAssemblyView.swift',
             'Tests/WoowAssistantUITests/SkillPDFAssemblyMultiFileUITests.swift',
             'scripts/check_pdf_pair_directory_creation.py', 'scripts/check_pdf_assembly_pair.py',
             'scripts/copy_skill_fixture_diagnostics.py']
    hashes = {}
    result = {'native_picker_UI': False, 'actual_macOS_PDFKit_and_NSFileCoordinator': True,
              'uses_stubs': False, 'source_snapshot_sha256': hashes, 'modes': {}}
    with tempfile.TemporaryDirectory(prefix='woow-pair-directory-check-') as temporary:
        work = Path(temporary)
        for name in names:
            content = (root / name).read_bytes()
            hashes[name] = hashlib.sha256(content).hexdigest()
            path = work / 'source' / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        support = work / 'source' / names[0]
        harness = work / 'Check.swift'
        harness.write_text(SWIFT)
        for mode, flags in [('debug', ['-D', 'DEBUG']), ('release', [])]:
            binary = work / mode
            run(['swiftc', '-warnings-as-errors', '-parse-as-library', *flags,
                 support, harness, '-o', binary], root, 90)
            stdout = run([binary, work / (mode + '-files')], root, 60)
            records, phases = [], []
            lines = stdout.splitlines()
            if not lines or not lines[-1].startswith('DIRECTORY_CREATION_CHECKS '):
                raise ValueError('missing_fixed_summary')
            for line in lines[:-1]:
                if mode != 'debug':
                    raise ValueError('release_diagnostics')
                if line.startswith(PAIR_MARKER):
                    records.append(checked(json.loads(line[len(PAIR_MARKER):])))
                    continue
                match = re.fullmatch(
                    r'SKILL_PDF_PAIR_CREATION namespace=[0-9A-F-]{36} mode=directoryCoordinated '
                    r'phase=(willCoordinate|completed|failed) coordinationAttempts=1 accessorCalls=([01]) '
                    r'createdFiles=([0-2]) existingFiles=([0-2])', line)
                if not match:
                    raise ValueError('unexpected_diagnostic')
                phases.append(match.groups())
            summary = json.loads(lines[-1].split(' ', 1)[1])
            groups = summary['groups']
            if (summary['native_picker_UI'] is not False or not groups
                    or any(type(n) is not int or n <= 0 for n in groups.values())
                    or summary['passed'] != sum(groups.values())):
                raise ValueError('invalid_fixed_counts')
            if mode == 'debug':
                if phases != [('willCoordinate', '0', '0', '0'), ('completed', '1', '2', '0'),
                              ('willCoordinate', '0', '0', '2'), ('completed', '1', '0', '2'),
                              ('willCoordinate', '0', '0', '0'), ('failed', '0', '0', '0')]:
                    raise ValueError('wrong_actual_coordination_events')
                if len(records) != 6 or any(v['evidence']['status'] != 'valid' for v in records):
                    raise ValueError('wrong_baseline_evidence')
                if set(groups) != {'gates', 'actual_creation', 'idempotence', 'cancelled_coordination',
                                   'directory_identity', 'unsafe_existing_files'}:
                    raise ValueError('missing_group')
            run(['swiftc', '-parse', '-target', 'arm64-apple-ios17.0', *flags,
                 *(work / 'source' / n for n in names[:3])], root, 30)
            result['modes'][mode] = dict(summary, baseline_records=len(records), creation_events=len(phases),
                                        ios17_syntax_parse=True)
            print(f'{mode.upper()} directory_creation={summary["passed"]} nativeUI=pending', flush=True)
        result['live_sources_match_snapshot'] = all(
            hashlib.sha256((root / name).read_bytes()).hexdigest() == digest for name, digest in hashes.items())
        if not result['live_sources_match_snapshot']:
            raise ValueError('sources_changed')
    if args.report:
        args.report.write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
