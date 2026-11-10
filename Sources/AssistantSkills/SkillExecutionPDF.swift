import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

enum SkillExecutionPDF {
    static var available: Bool {
        #if canImport(PDFKit)
        return true
        #else
        return false
        #endif
    }

    static func read(_ selected: SkillExecutionSelectedFile) throws -> Data {
        let url = selected.url
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw SkillExecutionError.invalidSelection }
            guard (values.fileSize ?? 0) <= SkillExecutionLimits.fileBytes else { throw SkillExecutionError.fileTooLarge }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            // Bound the actual read as well as the preflight size (file may change).
            let bytes = try handle.read(upToCount: SkillExecutionLimits.fileBytes + 1) ?? Data()
            guard bytes.count <= SkillExecutionLimits.fileBytes else { throw SkillExecutionError.fileTooLarge }
            guard bytes.starts(with: Data("%PDF-".utf8)) else { throw SkillExecutionError.invalidPDF }
            return bytes
        } catch let error as SkillExecutionError { throw error }
        catch { throw SkillExecutionError.invalidSelection }
    }

    static func extract(_ data: Data, options: SkillExecutionPDFOptions) throws -> SkillExecutionPDFResult {
        #if canImport(PDFKit)
        guard data.count <= SkillExecutionLimits.fileBytes else { throw SkillExecutionError.fileTooLarge }
        guard let document = PDFDocument(data: data) else { throw SkillExecutionError.invalidPDF }
        if document.isLocked {
            guard let password = options.password, document.unlock(withPassword: password) else { throw SkillExecutionError.passwordRequired }
        }
        let count = document.pageCount
        guard count > 0 else { throw SkillExecutionError.invalidPDF }
        let attributes = document.documentAttributes ?? [:]
        var metadata: [String: String] = ["pages": String(count)]
        for (key, value) in attributes {
            // PDF metadata is untrusted content. Bound output and keep it out of logs.
            let label = String(describing: key).lowercased()
            guard label.utf8.count <= 256 else { throw SkillExecutionError.outputTooLarge }
            let text = String(describing: value)
            guard text.utf8.count <= 64 * 1024 else { throw SkillExecutionError.outputTooLarge }
            metadata[label] = text
        }
        var pages: [SkillExecutionPDFPage] = []
        var outputBytes = metadata.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        if !options.metadataOnly {
            for number in try SkillExecutionPageRange.parse(options.pages, pageCount: count) {
                try Task.checkCancellation()
                guard let page = document.page(at: number - 1) else { throw SkillExecutionError.invalidPDF }
                let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                outputBytes += text.utf8.count + 32
                guard outputBytes <= SkillExecutionLimits.outputBytes else { throw SkillExecutionError.outputTooLarge }
                pages.append(SkillExecutionPDFPage(number: number, text: text))
            }
        }
        guard outputBytes <= SkillExecutionLimits.outputBytes else { throw SkillExecutionError.outputTooLarge }
        return SkillExecutionPDFResult(pageCount: count, pages: pages, metadata: metadata,
            emptyPages: pages.filter { $0.text.isEmpty }.map(\.number), inputSHA256: skillExecutionDigest(data),
            engine: "Apple PDFKit", originalScriptSHA256: nil)
        #else
        throw SkillExecutionError.unavailable
        #endif
    }
}
