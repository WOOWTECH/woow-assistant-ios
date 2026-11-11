#!/usr/bin/env python3
"""Check the file-coordinated synthetic pair with real macOS PDFKit/NSFileCoordinator.

This host check does not exercise Files, UIDocumentPicker, or FileProvider.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import tempfile

from check_pdf_assembly_pair import run
from copy_skill_fixture_diagnostics import PAIR_MARKER, checked

SWIFT = r'''
import Foundation
#if DEBUG
import CryptoKit
import PDFKit
#endif

@main struct CheckFileCreation {
    typealias Support = SkillExecutionUITestSupport
    struct Failed: Error { let code: String }
    static var checks = 0
    static func check(_ value: Bool, _ code: String) throws {
        guard value else { throw Failed(code: code) }
        checks += 1
    }
    static func reject(_ body: () throws -> Void) throws {
        do { try body(); throw Failed(code: "unexpected_success") }
        catch is Support.Failure { checks += 1 }
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let id = UUID(uuidString: "A1234567-89AB-4CDE-8123-456789ABCDEF")!
        let base = ["-UITestMode", "-UITestSkillExecution", "-UITestNamespace", id.uuidString,
                    "-UITestSkillAssemblyPair"]
        let flag = "-UITestSkillAssemblyPairFileCoordinatedCreation"
        let candidate = base + [flag]
        #if DEBUG
        for invalid in [candidate + [flag],
                        candidate + ["-UITestSkillAssemblyPairDirectoryCoordinatedCreation"],
                        candidate + ["-UITestSkillAssemblyPairUnknown"],
                        candidate + ["-LiveModelUITest"],
                        candidate.filter { $0 != "-UITestSkillAssemblyPair" },
                        candidate.filter { $0 != "-UITestMode" }] {
            var touched = false
            try reject {
                _ = try Support.seedAssemblyPairIfRequested(arguments: invalid,
                    documentsDirectory: { touched = true; return root })
            }
            try check(!touched, "invalid_gate_before_documents")
        }
        let candidateDirectory = root.appendingPathComponent("candidate", isDirectory: true)
        let pair = try Support.seedAssemblyPairIfRequested(arguments: candidate,
            documentsDirectory: { candidateDirectory })!
        try check(pair.creationProof.accessibilityValue ==
            "creation=fileCoordinated coordinationAttempts=2 accessorCalls=2 createdFiles=2 existingFiles=0",
            "two_exact_file_write_claims")
        try check(pair.sources.count == 2 && Set(pair.sources.map(\.sha256)).count == 2,
                  "two_distinct_real_pdfs")
        var identities: [String: UInt64] = [:]
        var originals: [String: Data] = [:]
        for (index, role) in ["A", "B"].enumerated() {
            let source = pair.sources[index]
            try check(source.role == role && source.url == candidateDirectory.appendingPathComponent(
                "SkillAssembly-\(role)-\(id.uuidString).pdf"), "exact_source_url")
            let data = try Data(contentsOf: source.url)
            originals[role] = data
            try check(data.count > 0 && data.count <= 128 * 1024 && data.starts(with: Data("%PDF-".utf8)),
                      "bounded_actual_pdf")
            try check(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == source.sha256,
                      "actual_pdf_digest")
            let pdf = PDFDocument(data: data)!
            try check(pdf.pageCount == 2, "two_actual_pages")
            for page in 1...2 {
                try check(pdf.page(at: page - 1)?.string?.contains("WOOW_ASSEMBLY_\(role)_PAGE_\(page)") == true,
                          "actual_page_marker")
            }
            let sample = Support.pairFixtureSample(in: candidateDirectory, namespace: id, role: role)
            try check(sample.0.status == "valid" && sample.0.sha256 == source.sha256,
                      "same_POSIX_observer")
            identities[role] = sample.0.inode!
        }
        let again = try Support.seedAssemblyPairIfRequested(arguments: candidate,
            documentsDirectory: { candidateDirectory })!
        try check(again.creationProof.accessibilityValue ==
            "creation=fileCoordinated coordinationAttempts=0 accessorCalls=0 createdFiles=0 existingFiles=2",
            "existing_files_not_rewritten")
        for source in again.sources {
            try check(try Data(contentsOf: source.url) == originals[source.role]!, "original_bytes_retained")
            try check(Support.pairFixtureSample(in: candidateDirectory, namespace: id, role: source.role).0.inode
                      == identities[source.role]!, "original_inode_retained")
        }
        let cancelledDirectory = root.appendingPathComponent("cancelled", isDirectory: true)
        let cancelled = NSFileCoordinator(); cancelled.cancel()
        try reject {
            _ = try Support.seedAssemblyPairIfRequested(arguments: candidate,
                fileCoordinator: cancelled, documentsDirectory: { cancelledDirectory })
        }
        try check(try FileManager.default.contentsOfDirectory(atPath: cancelledDirectory.path).isEmpty,
                  "cancelled_claim_has_no_direct_write_fallback")
        let badDirectory = root.appendingPathComponent("bad", isDirectory: true)
        try FileManager.default.createDirectory(at: badDirectory, withIntermediateDirectories: true)
        let a = badDirectory.appendingPathComponent("SkillAssembly-A-\(id.uuidString).pdf")
        let b = badDirectory.appendingPathComponent("SkillAssembly-B-\(id.uuidString).pdf")
        let sentinel = Data("INVALID_SYNTHETIC_B".utf8)
        try sentinel.write(to: b)
        try reject {
            _ = try Support.seedAssemblyPairIfRequested(arguments: candidate,
                documentsDirectory: { badDirectory })
        }
        try check(!FileManager.default.fileExists(atPath: a.path) && (try Data(contentsOf: b)) == sentinel,
                  "invalid_existing_B_prevents_any_A_write")
        #else
        var touched = false
        let result = try Support.seedIfRequested(arguments: candidate,
            documentsDirectory: { touched = true; return root })
        try check(result == nil && !touched && !FileManager.default.fileExists(atPath: root.path),
                  "release_inert")
        #endif
        print("FILE_CREATION_CHECKS passed=\(checks) nativePicker=false")
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    names = ['Sources/App/SkillExecutionUITestSupport.swift',
             'Tests/WoowAssistantUITests/SkillPDFAssemblyMultiFileUITests.swift',
             'scripts/check_pdf_pair_file_creation.py']
    hashes = {name: hashlib.sha256((repo / name).read_bytes()).hexdigest() for name in names}
    result = {'source_snapshot_sha256': hashes, 'native_picker_UI': False,
              'actual_macOS_PDFKit_and_NSFileCoordinator': True, 'modes': {}}
    with tempfile.TemporaryDirectory(prefix='woow-pair-file-check-') as temporary:
        work = Path(temporary)
        support = work / 'Support.swift'
        support.write_bytes((repo / names[0]).read_bytes())
        tests = work / 'UITests.swift'
        tests.write_bytes((repo / names[1]).read_bytes())
        harness = work / 'Check.swift'
        harness.write_text(SWIFT)
        for mode, flags in [('debug', ['-D', 'DEBUG']), ('release', [])]:
            binary = work / mode
            run(['swiftc', '-warnings-as-errors', '-parse-as-library', *flags,
                 support, harness, '-o', binary], repo, 90)
            stdout = run([binary, work / (mode + '-files')], repo, 60)
            events, baselines = [], []
            lines = stdout.splitlines()
            match = re.fullmatch(r'FILE_CREATION_CHECKS passed=(\d+) nativePicker=false',
                                 lines[-1] if lines else '')
            if not match:
                raise ValueError('missing_fixed_summary')
            for line in lines[:-1]:
                if mode != 'debug':
                    raise ValueError('release_diagnostic')
                if line.startswith(PAIR_MARKER):
                    baselines.append(checked(json.loads(line[len(PAIR_MARKER):])))
                    continue
                event = re.fullmatch(
                    r'SKILL_PDF_PAIR_CREATION namespace=[0-9A-F-]{36} mode=fileCoordinated '
                    r'phase=(willCoordinate|completed|failed) coordinationAttempts=([0-2]) '
                    r'accessorCalls=([0-2]) createdFiles=([0-2]) existingFiles=([0-2])', line)
                if not event:
                    raise ValueError('unexpected_diagnostic')
                events.append(event.groups())
            if mode == 'debug':
                expected = [('willCoordinate', '0', '0', '0', '0'),
                            ('completed', '2', '2', '2', '0'),
                            ('willCoordinate', '0', '0', '0', '2'),
                            ('completed', '0', '0', '0', '2'),
                            ('willCoordinate', '0', '0', '0', '0'),
                            ('failed', '1', '0', '0', '0')]
                if events != expected or len(baselines) != 4:
                    raise ValueError('incorrect_claim_or_baseline_events')
                if any(entry['evidence']['status'] != 'valid' for entry in baselines):
                    raise ValueError('invalid_fixture_baseline')
            run(['swiftc', '-parse', '-target', 'arm64-apple-ios17.0', *flags,
                 support, tests], repo, 30)
            result['modes'][mode] = {'checks_passed': int(match.group(1)),
                                     'claim_events': len(events), 'baseline_records': len(baselines),
                                     'ios17_syntax_parse': True}
            print(f'{mode.upper()} file_creation={match.group(1)} nativeUI=pending', flush=True)
    if not all(hashlib.sha256((repo / name).read_bytes()).hexdigest() == digest
               for name, digest in hashes.items()):
        raise ValueError('sources_changed_during_check')
    if args.report:
        args.report.write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
