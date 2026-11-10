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
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            // Coordination can resolve a symlink. Reject the selected link itself
            // before allowing Foundation to resolve the selected file's location.
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw SkillExecutionError.invalidSelection
            }
            var coordinationError: NSError?
            var snapshot: Result<Data, Error>?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
                snapshot = Result {
                    try Task.checkCancellation()
                    // Use only the accessor URL supplied for this selected item.
                    // File providers may move/materialize it during coordination.
                    let values = try coordinatedURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { throw SkillExecutionError.invalidSelection }
                    guard (values.fileSize ?? 0) <= SkillExecutionLimits.fileBytes else { throw SkillExecutionError.fileTooLarge }
                    let handle = try FileHandle(forReadingFrom: coordinatedURL)
                    defer { try? handle.close() }
                    // Bound the actual read too, including noncooperating writers.
                    let bytes = try handle.read(upToCount: SkillExecutionLimits.fileBytes + 1) ?? Data()
                    guard bytes.count <= SkillExecutionLimits.fileBytes else { throw SkillExecutionError.fileTooLarge }
                    guard bytes.starts(with: Data("%PDF-".utf8)) else { throw SkillExecutionError.invalidPDF }
                    return bytes
                }
            }
            try Task.checkCancellation()
            guard coordinationError == nil, let snapshot else { throw SkillExecutionError.invalidSelection }
            return try snapshot.get()
        } catch let error as SkillExecutionError { throw error }
        catch is CancellationError { throw CancellationError() }
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
