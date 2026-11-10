import CryptoKit
import Foundation

public enum DocumentQueryError: String, Error, Equatable, Sendable, LocalizedError {
    case invalidSource, emptySource, sourceTooLarge, invalidQuestion, invalidLimits
    case invalidRange, invalidSearch, invalidEvidence, invalidCommand
    case budgetExceeded, outputTooLarge, cancelled, timedOut, contextChanged, modelFailed

    public var errorDescription: String? {
        switch self {
        case .invalidSource: return "PDF 擷取結果無法驗證，請重新完成擷取。"
        case .emptySource: return "這份擷取結果沒有可查詢的文字；不提供 OCR。"
        case .sourceTooLarge: return "擷取文字超過 2 MiB，請縮小選取頁碼。"
        case .invalidQuestion: return "請輸入查詢問題，長度不得超過 4 KiB。"
        case .invalidLimits: return "文件查詢的執行限制無效。"
        case .invalidRange: return "模型要求的頁面或 UTF-8 讀取範圍無效。"
        case .invalidSearch: return "搜尋詞或搜尋結果數量超過限制。"
        case .invalidEvidence: return "回答引文無法在本次實際讀取範圍逐字核對。"
        case .invalidCommand: return "模型未提供有效的單一步驟文件指令。"
        case .budgetExceeded: return "文件查詢已達回合或內容上限，尚未完成。"
        case .outputTooLarge: return "文件查詢的回應超過資料上限。"
        case .cancelled: return "已取消文件查詢，沒有傳送新的讀取內容。"
        case .timedOut: return "文件查詢已超過執行時間，尚未完成。"
        case .contextChanged: return "來源或模型設定已變更，請重新確認目的服務。"
        case .modelFailed: return "模型服務未完成文件查詢，沒有自動重試。"
        }
    }
}

public struct DocumentTextPage: Sendable {
    /// One-based selection index. Repeated original pages retain distinct indices.
    public let index: Int
    public let pageNumber: Int
    public let text: String
    public let sha256: String
    public var byteCount: Int { bytes.count }
    let bytes: Data
}

/// Trusted host boundary: construct only from an actual completed PDF runtime
/// result, after its separate read/extract approvals. This validates data; it
/// neither grants model transmission consent nor reads a file/URL. No Codable.
public struct DocumentTextSnapshot: Sendable, Identifiable {
    public static let maximumBytes = 2 * 1024 * 1024
    public let id: UUID
    public let filename: String
    /// Original PDF's page count, not the selected occurrence count.
    public let pageCount: Int
    public let pages: [DocumentTextPage]
    public let byteCount: Int
    public let inputSHA256: String
    public let textSHA256: String
    /// Hash binds source identity, engine, original provenance and ordered pages.
    public let sha256: String
    public let engine: String
    public let originalScriptSHA256: String?
    public let provenance: [SkillExecutionProvenance]
    let referenceInstruction: String

    public init(result: SkillExecutionPDFResult, filename: String, catalog: BundledSkillCatalog) throws {
        guard !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              filename.utf8.count <= 512, !filename.contains("/"), !filename.contains("\\"),
              !filename.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              result.pageCount > 0, validDocumentDigest(result.inputSHA256),
              let entry = catalog.entry(id: "documents"),
              let script = entry.assets.first(where: { $0.path.hasSuffix("/scripts/extract_pdf.py") }) else {
            throw DocumentQueryError.invalidSource
        }
        switch (result.engine, result.originalScriptSHA256) {
        case ("Apple PDFKit", nil): break
        case ("Mika extract_pdf.py / pypdf", let actual?) where actual == script.sha256: break
        default: throw DocumentQueryError.invalidSource
        }
        guard !result.pages.isEmpty else { throw DocumentQueryError.emptySource }
        guard result.pages.count <= SkillExecutionLimits.pages else { throw DocumentQueryError.sourceTooLarge }
        var built: [DocumentTextPage] = [], total = 0
        for (index, page) in result.pages.enumerated() {
            guard page.number >= 1, page.number <= result.pageCount else { throw DocumentQueryError.invalidSource }
            let bytes = Data(page.text.utf8)
            guard bytes.count <= Self.maximumBytes - total else { throw DocumentQueryError.sourceTooLarge }
            total += bytes.count
            built.append(.init(index: index + 1, pageNumber: page.number, text: page.text,
                               sha256: documentDigest(bytes), bytes: bytes))
        }
        guard built.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw DocumentQueryError.emptySource
        }
        let provenance = ([entry.original] + entry.assets).map(SkillExecutionProvenance.init)
        // Length-framed JSON strings and arrays, never text page-marker parsing.
        let pageManifest: [[String: Any]] = built.map {
            ["index": $0.index, "page_number": $0.pageNumber, "bytes": $0.byteCount, "sha256": $0.sha256]
        }
        let textHash = documentDigest(try JSONSerialization.data(withJSONObject: pageManifest, options: [.sortedKeys]))
        let identity: [String: Any] = ["filename": filename, "page_count": result.pageCount,
            "input_sha256": result.inputSHA256, "text_sha256": textHash, "engine": result.engine,
            "script_sha256": result.originalScriptSHA256 ?? "", "provenance": provenance.map {
                ["repository": $0.repository, "revision": $0.revision, "path": $0.path, "sha256": $0.sha256]
            }]
        id = UUID(); self.filename = filename; pageCount = result.pageCount; pages = built; byteCount = total
        inputSHA256 = result.inputSHA256; textSHA256 = textHash; engine = result.engine
        originalScriptSHA256 = result.originalScriptSHA256; self.provenance = provenance
        referenceInstruction = entry.original.content
        sha256 = documentDigest(try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys]))
    }
}

public struct DocumentTextRead: Sendable, Encodable, Identifiable {
    public let id: UUID
    public let pageIndex: Int
    public let pageNumber: Int
    public let offset: Int
    public let length: Int
    public let text: String
    public let sourceSHA256: String
}

public struct DocumentSearchHit: Sendable, Encodable {
    public let pageIndex: Int
    public let pageNumber: Int
    public let offset: Int
    public let length: Int
    public let snippetOffset: Int
    public let snippet: String
}

public struct DocumentSearchResult: Sendable, Encodable {
    public let hits: [DocumentSearchHit]
    /// True means more hits exist; search stopped at the next hit. No total count
    /// or whole-document absence claim is made from a truncated result.
    public let truncated: Bool
    public let sourceSHA256: String
}

public struct DocumentCitation: Sendable, Identifiable {
    public var id: String { "\(readID.uuidString):\(offset):\(quote.utf8.count)" }
    public let readID: UUID
    public let pageIndex: Int
    public let pageNumber: Int
    /// UTF-8 byte offset within this selected page occurrence.
    public let offset: Int
    public let quote: String
    public let sourceSHA256: String
}

/// In-memory tools over exactly one approved extraction. Search snippets never
/// enter the read ledger and cannot become citations until an explicit read.
public struct DocumentTextTools: Sendable {
    public let source: DocumentTextSnapshot
    public private(set) var reads: [DocumentTextRead] = []
    public init(source: DocumentTextSnapshot) { self.source = source }

    public mutating func read(pageIndex: Int, offset: Int, limit: Int) throws -> DocumentTextRead {
        guard pageIndex > 0, source.pages.indices.contains(pageIndex - 1),
              offset >= 0, (1...8192).contains(limit) else { throw DocumentQueryError.invalidRange }
        let page = source.pages[pageIndex - 1], bytes = source.pages[pageIndex - 1].bytes
        guard offset < bytes.count, documentBoundary(bytes, offset) else { throw DocumentQueryError.invalidRange }
        var end = offset + min(limit, bytes.count - offset)
        while end > offset && !documentBoundary(bytes, end) { end -= 1 }
        guard end > offset else { throw DocumentQueryError.invalidRange }
        guard reads.count < 12 else { throw DocumentQueryError.budgetExceeded }
        let read = DocumentTextRead(id: UUID(), pageIndex: pageIndex, pageNumber: page.pageNumber,
            offset: offset, length: end - offset, text: String(decoding: bytes[offset..<end], as: UTF8.self), sourceSHA256: source.sha256)
        reads.append(read)
        return read
    }

    public func search(query: String, limit: Int = 10) throws -> DocumentSearchResult {
        let needle = Data(query.utf8)
        guard (1...256).contains(needle.count), (1...20).contains(limit),
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !query.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw DocumentQueryError.invalidSearch
        }
        var hits: [DocumentSearchHit] = []
        for page in source.pages {
            var cursor = 0
            while cursor < page.byteCount,
                  let range = page.bytes.range(of: needle, in: cursor..<page.byteCount) {
                try Task.checkCancellation()
                guard hits.count < limit else { return .init(hits: hits, truncated: true, sourceSHA256: source.sha256) }
                // Literal valid UTF-8 matching cannot begin inside a continuation
                // byte; boundary checks also document the byte-offset contract.
                guard documentBoundary(page.bytes, range.lowerBound), documentBoundary(page.bytes, range.upperBound) else {
                    throw DocumentQueryError.invalidSearch
                }
                var start = max(0, range.lowerBound - 64)
                while !documentBoundary(page.bytes, start) { start += 1 }
                var end = min(page.byteCount, max(range.upperBound, start + 320))
                while !documentBoundary(page.bytes, end) { end -= 1 }
                hits.append(.init(pageIndex: page.index, pageNumber: page.pageNumber, offset: range.lowerBound,
                    length: needle.count, snippetOffset: start,
                    snippet: String(decoding: page.bytes[start..<end], as: UTF8.self)))
                cursor = range.upperBound
            }
        }
        return .init(hits: hits, truncated: false, sourceSHA256: source.sha256)
    }

    public func citation(readID: UUID, offset: Int, quote: String) throws -> DocumentCitation {
        let bytes = Data(quote.utf8)
        guard let read = reads.first(where: { $0.id == readID }), (1...4096).contains(bytes.count),
              offset >= read.offset, offset - read.offset <= read.length,
              bytes.count <= read.length - (offset - read.offset) else { throw DocumentQueryError.invalidEvidence }
        let page = source.pages[read.pageIndex - 1]
        guard documentBoundary(page.bytes, offset), documentBoundary(page.bytes, offset + bytes.count),
              page.bytes.subdata(in: offset..<(offset + bytes.count)) == bytes else { throw DocumentQueryError.invalidEvidence }
        return .init(readID: read.id, pageIndex: read.pageIndex, pageNumber: read.pageNumber,
                     offset: offset, quote: quote, sourceSHA256: source.sha256)
    }
}

private func documentBoundary(_ bytes: Data, _ offset: Int) -> Bool {
    offset >= 0 && offset <= bytes.count && (offset == bytes.count || bytes[offset] & 0xC0 != 0x80)
}
private func validDocumentDigest(_ text: String) -> Bool {
    text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
private func documentDigest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
