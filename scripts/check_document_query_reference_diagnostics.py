#!/usr/bin/env python3
"""Exercise the exact pure live-probe observer offline; no model or credentials."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
source = repo / 'scripts/LiveDocumentQueryReferenceSmoke.swift'
text = source.read_text()
start = '// BEGIN PURE PREFIX DIAGNOSTICS'
end = '// END PURE PREFIX DIAGNOSTICS'
assert text.count(start) == text.count(end) == 1
segment = text[text.index(start):text.index(end)]
driver = r'''
@main enum Checks {
    static func main() throws {
        let saved = "SAVED_PDF_12345678-1234-1234-1234-123456789ABC"
        let current = "CURRENT_PDF_ABCDEF12-1234-1234-1234-123456789ABC"
        let cases: [(String, PDFReferencePrefixCategory)] = [
            (saved + " answer", .exact),
            (" \n" + saved + " answer", .leadingWhitespace),
            ("**" + saved + "** answer", .markdownWrapped),
            ("`" + saved + "` answer", .markdownWrapped),
            ("## " + saved + " answer", .markdownWrapped),
            (saved + "\nanswer", .newline),
            (saved + "\r\nanswer", .newline),
            (saved + "\tanswer", .tab),
            (saved + "\u{00a0}answer", .otherWhitespace),
            (saved, .endWithoutSpace),
            (saved + ": answer", .otherSeparator),
            ("Answer includes " + saved, .laterInAnswer),
            (saved.lowercased() + " answer", .caseChanged),
            ("SAVED_PDF_99999999-1234-1234-1234-123456789ABC answer", .uuidChanged),
            ("SAVED_PDF_broken answer", .tokenAltered),
            ("Answer without marker", .absent)]
        var count = 0
        func check(_ value: Bool) { precondition(value, "Fixed diagnostic regression"); count += 1 }
        for (answer, expected) in cases {
            let observation = PDFReferencePrefixObservation.inspect(answer: answer, expected: saved, saved: saved)
            check(observation.category == expected)
            check(observation.answerUTF8Bytes == answer.utf8.count)
            // Diagnostic matching must never turn a wrapper/whitespace/UUID
            // approximation into the original exact-prefix acceptance.
            check(answer.hasPrefix(saved + " ") == (expected == .exact))
            let encoded = String(decoding: try JSONEncoder().encode(observation), as: UTF8.self)
            check(!encoded.contains(saved) && !encoded.contains("123456789ABC") && !encoded.contains(answer))
        }
        let mixed = current + " answer " + saved
        let observation = PDFReferencePrefixObservation.inspect(answer: mixed, expected: current, saved: saved)
        check(observation.category == .exact && observation.savedTokenPresent)
        check(!(mixed.hasPrefix(current + " ") && !mixed.contains(saved)))
        check(PDFReferencePrefixObservation().category == .notChecked)
        check(PDFReferenceOutcome.notChecked.rawValue != PDFReferenceOutcome.fail.rawValue)
        print("{\"passed\":\(count),\"failed\":0,\"http_attempts\":0}")
    }
}
'''
out = Path(tempfile.mkdtemp(prefix='woow-pdf-reference-diagnostics-'))
swift = out / 'checks.swift'
swift.write_text('import Foundation\n' + segment + '\n' + driver)
env = {k: v for k, v in os.environ.items() if k in ('PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL')}
subprocess.run(['swiftc', '-swift-version', '5', '-warnings-as-errors', '-parse-as-library', str(swift), '-o', str(out / 'checks')], env=env, check=True, timeout=60)
result = subprocess.run([str(out / 'checks')], env=env, capture_output=True, check=True, timeout=15)
report = {'result': json.loads(result.stdout), 'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
          'exact_extracted_segment_sha256': hashlib.sha256(segment.encode()).hexdigest(), 'no_source_substitution': True}
(out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, sort_keys=True))
print('REPORT=' + str(out / 'report.json'))
