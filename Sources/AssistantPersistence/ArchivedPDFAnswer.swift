import CryptoKit
import Foundation

/// Display/evidence data only. Decoding never constructs a file selection,
/// runtime, model destination approval or executable tool receipt.
public struct ArchivedPDFAnswer: Codable, Equatable, Sendable {
    public struct Page: Codable, Equatable, Sendable {
        public let number: Int
        public let text: String
        public init(number: Int, text: String) { self.number = number; self.text = text }
    }
    public struct Citation: Codable, Equatable, Sendable {
        public let readID: UUID
        public let pageIndex: Int
        public let readOffset: Int
        public let readLength: Int
        public let offset: Int
        public let quote: String
        public init(readID: UUID, pageIndex: Int, readOffset: Int, readLength: Int, offset: Int, quote: String) {
            self.readID = readID; self.pageIndex = pageIndex; self.readOffset = readOffset
            self.readLength = readLength; self.offset = offset; self.quote = quote
        }
    }
    public static let maximumTextBytes = 2 * 1024 * 1024
    public let filename: String
    public let inputSHA256: String
    public let originalPageCount: Int
    public let pages: [Page]
    public let citations: [Citation]
    public let textSHA256: String
    private let version = 1

    public init(filename: String, inputSHA256: String, originalPageCount: Int,
                pages: [Page], citations: [Citation]) throws {
        guard !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              filename.utf8.count <= 512, !filename.contains("/"), !filename.contains("\\"),
              !filename.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              inputSHA256.count == 64, inputSHA256.allSatisfy({ "0123456789abcdef".contains($0) }),
              originalPageCount > 0, (1...200).contains(pages.count), (1...16).contains(citations.count)
        else { throw ConversationArchiveError.invalidData }
        var bytes = 0
        for page in pages {
            guard (1...originalPageCount).contains(page.number), page.text.utf8.count <= Self.maximumTextBytes - bytes
            else { throw ConversationArchiveError.invalidData }
            bytes += page.text.utf8.count
        }
        guard bytes > 0 else { throw ConversationArchiveError.invalidData }
        for citation in citations {
            guard (1...pages.count).contains(citation.pageIndex), citation.readOffset >= 0,
                  (1...8192).contains(citation.readLength), citation.offset >= citation.readOffset,
                  !citation.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  citation.quote.utf8.count <= 4096 else { throw ConversationArchiveError.invalidData }
            let data = Data(pages[citation.pageIndex - 1].text.utf8)
            guard citation.readOffset <= data.count, citation.readLength <= data.count - citation.readOffset,
                  citation.offset <= citation.readOffset + citation.readLength,
                  citation.quote.utf8.count <= citation.readOffset + citation.readLength - citation.offset,
                  String(data: data.subdata(in: citation.readOffset..<(citation.readOffset + citation.readLength)), encoding: .utf8) != nil,
                  data.subdata(in: citation.offset..<(citation.offset + citation.quote.utf8.count)) == Data(citation.quote.utf8)
            else { throw ConversationArchiveError.invalidData }
        }
        guard Set(citations.map { $0.readID.uuidString + ":" + String($0.offset) + ":" + $0.quote }).count == citations.count
        else { throw ConversationArchiveError.invalidData }
        // A read ID always identifies the same source range, even when cited twice.
        for citation in citations {
            guard citations.filter({ $0.readID == citation.readID }).allSatisfy({
                $0.pageIndex == citation.pageIndex && $0.readOffset == citation.readOffset && $0.readLength == citation.readLength
            }) else { throw ConversationArchiveError.invalidData }
        }
        self.filename = filename; self.inputSHA256 = inputSHA256; self.originalPageCount = originalPageCount
        self.pages = pages; self.citations = citations
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        textSHA256 = SHA256.hash(data: try encoder.encode(pages)).map { String(format: "%02x", $0) }.joined()
    }

    private enum CodingKeys: String, CodingKey { case version, filename, inputSHA256, originalPageCount, pages, citations, textSHA256 }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .version) == 1 else { throw ConversationArchiveError.invalidData }
        try self.init(filename: c.decode(String.self, forKey: .filename), inputSHA256: c.decode(String.self, forKey: .inputSHA256),
                      originalPageCount: c.decode(Int.self, forKey: .originalPageCount), pages: c.decode([Page].self, forKey: .pages),
                      citations: c.decode([Citation].self, forKey: .citations))
        guard try c.decode(String.self, forKey: .textSHA256) == textSHA256 else { throw ConversationArchiveError.invalidData }
    }
}
