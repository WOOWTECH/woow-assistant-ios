import Foundation
#if DEBUG
import CoreGraphics
import CoreText
import PDFKit
#endif

/// No startup hook is required: SkillExecutionView calls seedIfRequested on appear.
/// DEBUG + -UITestMode + -UITestSkillExecution + exactly one valid
/// -UITestNamespace UUID are required. This never selects, reads or approves a
/// runtime input. Release/default calls return before touching the filesystem.
enum SkillExecutionUITestSupport {
    struct Fixture {
        let namespace: UUID
        let url: URL
        var filename: String { url.lastPathComponent }
    }
    enum Failure: Error { case invalidNamespace, cannotCreatePDF, existingFile }

    static func seedIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments,
                                documentsDirectory: () throws -> URL = {
                                    try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                                appropriateFor: nil, create: true)
                                }) throws -> Fixture? {
        #if DEBUG
        guard arguments.contains("-UITestSkillExecution") else { return nil }
        guard arguments.filter({ $0 == "-UITestSkillExecution" }).count == 1,
              arguments.filter({ $0 == "-UITestMode" }).count == 1,
              arguments.filter({ $0 == "-UITestNamespace" }).count == 1,
              !arguments.contains(where: { $0.hasPrefix("-Live") }),
              let index = arguments.firstIndex(of: "-UITestNamespace"), arguments.indices.contains(index + 1),
              let namespace = UUID(uuidString: arguments[index + 1]) else { throw Failure.invalidNamespace }
        // Do not even resolve/create Documents until all fixture gates pass.
        let root = try documentsDirectory()
        let url = root.appendingPathComponent("SkillExecution-\(namespace.uuidString).pdf")
        let fixture = Fixture(namespace: namespace, url: url)
        let title = "WOOW_SKILL_PDF_FIXTURE_" + namespace.uuidString
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 128 * 1024,
                  let document = PDFDocument(url: url), document.pageCount == 2,
                  document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == title else {
                throw Failure.existingFile
            }
            return fixture // Re-entering the view never overwrites another file.
        }
        let buffer = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: buffer),
              let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { throw Failure.cannotCreatePDF }
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        for number in 1...2 {
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 40, y: 700)
            let marker = NSAttributedString(string: "WOOW_SKILL_PDF_PAGE_\(number)", attributes: attributes)
            CTLineDraw(CTLineCreateWithAttributedString(marker), context)
            context.textPosition = CGPoint(x: 40, y: 660)
            let scope = NSAttributedString(string: namespace.uuidString, attributes: attributes)
            CTLineDraw(CTLineCreateWithAttributedString(scope), context)
            context.endPDFPage()
        }
        context.closePDF()
        guard let document = PDFDocument(data: buffer as Data), document.pageCount == 2 else { throw Failure.cannotCreatePDF }
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: title,
                                       PDFDocumentAttribute.authorAttribute: "Synthetic UI fixture"]
        guard let bytes = document.dataRepresentation(), bytes.count <= 128 * 1024 else { throw Failure.cannotCreatePDF }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try bytes.write(to: url, options: .withoutOverwriting)
        return fixture
        #else
        return nil
        #endif
    }
}

#if DEBUG
/// Per-view test-only evidence. Updated at real runtime dispatch/result boundaries,
/// not from expected test outcomes. Clear/cancel intentionally preserves counts.
struct SkillExecutionUITestAudit {
    var selections = 0
    var reads = 0
    var extractionAttempts = 0
    var results = 0
    var evidence: String {
        "SKILL_EXECUTION_AUDIT selections=\(selections) reads=\(reads) extractionAttempts=\(extractionAttempts) results=\(results)"
    }
}
#endif
