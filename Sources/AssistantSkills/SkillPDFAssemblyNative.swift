import Foundation
#if canImport(PDFKit) && !PDF_ASSEMBLY_NO_PDFKIT
import PDFKit
#endif

/// All PDFKit objects are confined to one synchronous invocation. Only immutable
/// bytes/receipts cross executors; this adapter never opens a filesystem URL.
enum SkillPDFAssemblyNative {
    static var available: Bool {
        #if canImport(PDFKit) && !PDF_ASSEMBLY_NO_PDFKIT
        return true
        #else
        return false
        #endif
    }

    static func inspect(_ bytes: Data) throws -> Int {
        try Task.checkCancellation()
        #if canImport(PDFKit) && !PDF_ASSEMBLY_NO_PDFKIT
        return try open(bytes).pageCount
        #else
        throw SkillExecutionError.unavailable
        #endif
    }

    static func assemble(_ inputs: [SkillPDFAssemblySnapshot], order: [SkillPDFAssemblyPage]) throws -> Data {
        try Task.checkCancellation()
        guard (1...SkillPDFAssemblyLimits.files).contains(inputs.count),
              Set(inputs.map { $0.receipt.id }).count == inputs.count else { throw SkillPDFAssemblyError.invalidSources }
        guard inputs.allSatisfy({ !$0.data.isEmpty && $0.data.count <= SkillPDFAssemblyLimits.inputBytes }),
              inputs.reduce(0, { $0 + $1.data.count }) <= SkillPDFAssemblyLimits.totalInputBytes else {
            throw SkillExecutionError.fileTooLarge
        }
        guard !order.isEmpty else { throw SkillExecutionError.invalidPages }
        guard order.count <= SkillPDFAssemblyLimits.pages else { throw SkillExecutionError.tooManyPages }
        let ids = Set(inputs.map { $0.receipt.id })
        guard order.allSatisfy({ ids.contains($0.sourceID) && $0.number > 0 }) else { throw SkillExecutionError.invalidPages }
        #if canImport(PDFKit) && !PDF_ASSEMBLY_NO_PDFKIT
        var documents: [UUID: PDFDocument] = [:]
        for input in inputs {
            try Task.checkCancellation()
            guard input.receipt.byteCount == input.data.count,
                  input.receipt.sha256 == skillExecutionDigest(input.data) else { throw SkillPDFAssemblyError.verification }
            let document = try open(input.data)
            guard document.pageCount == input.receipt.pageCount else { throw SkillPDFAssemblyError.verification }
            documents[input.receipt.id] = document
        }
        guard documents.values.reduce(0, { $0 + $1.pageCount }) <= SkillPDFAssemblyLimits.pages else {
            throw SkillExecutionError.tooManyPages
        }
        let output = PDFDocument()
        for reference in order {
            try Task.checkCancellation()
            guard let source = documents[reference.sourceID], reference.number <= source.pageCount,
                  let page = source.page(at: reference.number - 1) else { throw SkillExecutionError.invalidPages }
            guard page.annotations.isEmpty, let dictionary = page.pageRef?.dictionary else {
                throw SkillPDFAssemblyError.unsupportedDocument
            }
            try rejectKeys(["AA", "AF", "PresSteps"], in: dictionary)
            // A PDFPage has one owner. Never insert the original page object.
            guard let copy = page.copy() as? PDFPage else { throw SkillPDFAssemblyError.serialization }
            output.insert(copy, at: output.pageCount)
            guard page.document === source else { throw SkillPDFAssemblyError.verification }
        }
        try Task.checkCancellation()
        // PDFKit serialization is synchronous and cannot be forcibly interrupted.
        // Check cancellation on either side; bound accepted serialized output.
        guard let bytes = output.dataRepresentation() else { throw SkillPDFAssemblyError.serialization }
        try Task.checkCancellation()
        guard bytes.count <= SkillPDFAssemblyLimits.outputBytes else { throw SkillPDFAssemblyError.outputTooLarge }
        guard let reopened = PDFDocument(data: bytes), reopened.pageCount == order.count,
              !reopened.isEncrypted else { throw SkillPDFAssemblyError.verification }
        for (index, reference) in order.enumerated() {
            try Task.checkCancellation()
            guard let before = documents[reference.sourceID]?.page(at: reference.number - 1),
                  let after = reopened.page(at: index), after.rotation == before.rotation else {
                throw SkillPDFAssemblyError.verification
            }
            // PDFKit may translate the MediaBox origin and all content equally.
            // Compare dimensions and media-relative geometry, not raw origins.
            for box in boxes where !sameGeometry(relativeBounds(before, box), relativeBounds(after, box)) {
                throw SkillPDFAssemblyError.verification
            }
        }
        return bytes
        #else
        throw SkillExecutionError.unavailable
        #endif
    }

    #if canImport(PDFKit) && !PDF_ASSEMBLY_NO_PDFKIT
    static let boxes: [PDFDisplayBox] = [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox]
    static func relativeBounds(_ page: PDFPage, _ box: PDFDisplayBox) -> CGRect {
        let media = page.bounds(for: .mediaBox)
        return page.bounds(for: box).offsetBy(dx: -media.minX, dy: -media.minY)
    }
    static func sameGeometry(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        // Actual fractional PDFKit roundtrip: width 560.1234 differed by one
        // Double ULP (1.1368683772161603e-13 points) after origin translation;
        // rendered bytes were identical. Allow at most four representable steps
        // per component, never a broad point/percentage epsilon. Reject NaN/Inf.
        let a = [lhs.origin.x, lhs.origin.y, lhs.width, lhs.height]
        let b = [rhs.origin.x, rhs.origin.y, rhs.width, rhs.height]
        return zip(a, b).allSatisfy { expected, actual in
            guard expected.isFinite, actual.isFinite else { return false }
            return abs(expected - actual) <= 4 * max(expected.ulp, actual.ulp)
        }
    }
    private static func open(_ bytes: Data) throws -> PDFDocument {
        guard bytes.count <= SkillPDFAssemblyLimits.inputBytes else { throw SkillExecutionError.fileTooLarge }
        guard bytes.starts(with: Data("%PDF-".utf8)), let document = PDFDocument(data: bytes),
              document.pageCount > 0 else { throw SkillExecutionError.invalidPDF }
        guard document.pageCount <= SkillPDFAssemblyLimits.pages else { throw SkillExecutionError.tooManyPages }
        guard !document.isEncrypted, !document.isLocked, document.allowsCopying,
              document.allowsDocumentAssembly else { throw SkillPDFAssemblyError.protectedPDF }
        guard let provider = CGDataProvider(data: bytes as CFData), let cg = CGPDFDocument(provider),
              let catalog = cg.catalog else { throw SkillExecutionError.invalidPDF }
        // Copying individual pages does not safely preserve these document-wide
        // relationships. Fail explicitly instead of silently dropping them.
        try rejectKeys(["AcroForm", "Names", "OpenAction", "AA", "Perms", "Outlines", "Collection",
                        "StructTreeRoot", "OCProperties", "AF"], in: catalog)
        return document
    }
    private static func rejectKeys(_ keys: [String], in dictionary: CGPDFDictionaryRef) throws {
        for key in keys {
            var object: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(dictionary, key, &object) { throw SkillPDFAssemblyError.unsupportedDocument }
        }
    }
    #endif
}
